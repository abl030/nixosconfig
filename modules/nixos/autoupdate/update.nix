{
  lib,
  config,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.update;
  verifyCfg = config.homelab.update.verify;
  useVerifiedUpdate = verifyCfg.enable && verifyCfg.enforce;
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;
  diagnoseUser = hostConfig.user;
  diagnoseHome = hostConfig.homeDirectory or "/home/${diagnoseUser}";
in {
  options.homelab.update = {
    enable = lib.mkEnableOption "Nightly flake switch & housekeeping (via system.autoUpgrade + timers)";

    updateDates = lib.mkOption {
      type = lib.types.str;
      default = "01:00";
      description = "OnCalendar expression for system.autoUpgrade.";
    };

    collectGarbage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic nix-collect-garbage on a schedule.";
    };

    gcDates = lib.mkOption {
      type = lib.types.str;
      default = "02:00";
      description = "OnCalendar expression for nix.gc automatic GC.";
    };

    trim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic fstrim on a schedule.";
    };

    trimInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "OnCalendar-style interval for fstrim.";
    };

    wakeOnUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wake the system (from Suspend) for the update window.";
    };

    rebootOnKernelUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Reboot if kernel changes.";
    };

    # --- SMART UPDATE GATES ---
    checkAcPower = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Only update if on AC power (useful for laptops).";
    };

    checkWifi = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of allowed SSIDs. If empty, allows any connection.";
    };

    timeout = lib.mkOption {
      type = lib.types.str;
      default = "60min";
      description = "Maximum time allowed for the entire update operation (DNS check + rebuild + activation). Prevents hangs from stuck activations.";
    };

    diagnose = {
      enable = lib.mkEnableOption "Run claude -p on nixos-upgrade failure and post the diagnosis to Gotify (replaces the raw-log failure ping). Requires one-time interactive `sudo -u abl030 --login claude` per host.";
    };
  };

  config = lib.mkIf cfg.enable (let
    # Shared with base.nix's activation script. Runs BEFORE the flake
    # fetch so a stale PAT can't poison every github.com request with 401.
    # See docs/wiki/infrastructure/github-pat-and-private-inputs.md.
    refreshAccessTokens = import ../lib/refresh-access-tokens.nix {inherit pkgs;};

    diagnoseSystemPrompt = ''
      Diagnose tonight's nixos-rebuild failure on this host. Focus on what just broke; don't go hunting historical patterns.

      You have WebFetch. Loki (read-only, no auth) at https://loki.ablz.au:
        /loki/api/v1/query_range?query=<LogQL>&start=<RFC3339>&end=<RFC3339>&limit=<n>
      Labels: host, unit, container, app. Common hosts: doc2, epimetheus, framework, igpu, pfsense, prom, proxmox-vm, tower, wsl.

      Reply with exactly these four lines, starting with **Classification**, no preamble:

      **Classification**: upstream | actionable | transient
      **Summary**: what failed and why (1-2 sentences).
      **Fix**: concrete next step. If a workaround exists, give the Nix snippet (e.g. `systemd.services.<name>.serviceConfig.ExecStartPre = ["..."];`).
      **Evidence**: strongest signal you found.
    '';

    diagnoseScript = pkgs.writeShellScript "nixos-upgrade-diagnose" ''
      set -uo pipefail
      log_file=/var/lib/nixos-upgrade/last-failure.log
      if [ ! -e "$log_file" ]; then
        # No log file written → smartUpgrade either exited before reaching the
        # failure branch (rare, set -e crash) OR an earlier failure path was
        # taken. Fall back to journalctl for the failed unit invocation.
        echo "[Diagnose] No failure log at $log_file; falling back to journalctl tail."
        rebuild_log_block="$(${pkgs.systemd}/bin/journalctl -u nixos-upgrade.service -n 200 --no-pager 2>&1 || true)"
        log_source="journalctl"
      elif [ ! -r "$log_file" ]; then
        # File exists but the diagnose user can't read it. This was the
        # epimetheus 2026-05-25 bug — root-owned 0600 from cp of a mktemp.
        # We now install -m 0644 in smartUpgrade so this branch should be
        # unreachable; keep it as a loud guard.
        echo "[Diagnose] $log_file exists but is not readable as $(id -un) — perms bug, see modules/nixos/autoupdate/update.nix."
        rebuild_log_block="(failure log present but unreadable as $(id -un); fix perms in smartUpgrade)"
        log_source="perm-error"
      else
        # Plain tail. Wider/historical context is now fetched on demand by
        # claude via WebFetch → Loki, so we don't need to be clever here.
        rebuild_log_block="$(${pkgs.coreutils}/bin/tail -n 200 "$log_file")"
        log_source="$log_file"
      fi

      # HEAD diff: highest-signal "what just changed" pointer. Wider git
      # history is left to claude (it can query Loki for the
      # rolling-flake-update commit summary, or webfetch GitHub directly).
      diff_block="(no local checkout — diff unavailable on this host)"
      for repo in ${diagnoseHome}/nixosconfig /home/abl030/nixosconfig; do
        if [ -d "$repo/.git" ]; then
          cd "$repo"
          diff_block="$(${pkgs.git}/bin/git log -1 --stat 2>/dev/null || true)
      $(${pkgs.git}/bin/git diff HEAD~1 HEAD 2>/dev/null | ${pkgs.coreutils}/bin/head -n 200 || true)"
          break
        fi
      done

      # Failed system units: local, trivial, often dispositive.
      failed_system_block="$(${pkgs.systemd}/bin/systemctl list-units --failed --plain --no-pager --no-legend 2>&1 || echo '(systemctl list-units unavailable)')"

      # Failed user units: local-only — alloy doesn't ship the user journal
      # to Loki, so claude can't pull this on demand. Needs XDG_RUNTIME_DIR
      # to find the user's systemd --user instance. If no live session
      # (/run/user/$UID missing), gracefully skip.
      uid="$(id -u)"
      if [ -d "/run/user/$uid" ]; then
        failed_user_block="$(XDG_RUNTIME_DIR="/run/user/$uid" ${pkgs.systemd}/bin/systemctl --user list-units --failed --plain --no-pager --no-legend 2>&1 || echo '(user bus query failed)')"
      else
        failed_user_block="(no user session active — /run/user/$uid missing)"
      fi

      # Coredumps in the last 15 minutes: local-only. coredumpctl reads via
      # journal; the systemd-journal supplementary group gives us access.
      coredumps_block="$(${pkgs.systemd}/bin/coredumpctl list --since '15 min ago' --no-pager 2>&1 | ${pkgs.coreutils}/bin/tail -n 30 || echo '(coredumpctl unavailable)')"

      prompt="=== HOST ===

      ${config.networking.hostName}

      === HEAD DIFF (most likely root cause if classification=actionable) ===

      $diff_block

      === FAILED SYSTEM UNITS (now) ===

      $failed_system_block

      === FAILED USER UNITS (now) ===

      $failed_user_block

      === COREDUMPS (last 15 min) ===

      $coredumps_block

      === REBUILD LOG (last 200 lines from $log_source) ===

      $rebuild_log_block"

      summary="$(printf '%s' "$prompt" | ${pkgs.coreutils}/bin/timeout 600 ${pkgs.claude-code}/bin/claude -p \
        --system-prompt ${lib.escapeShellArg diagnoseSystemPrompt} \
        --model opus \
        --allowedTools WebFetch \
        "Diagnose tonight's failure." \
        2>&1)"
      claude_status=$?

      if [ $claude_status -ne 0 ] || [ -z "$summary" ]; then
        echo "[Diagnose] claude triage unavailable (status=$claude_status); falling back to raw log tail."
        summary="(claude triage unavailable, raw rebuild log slice follows)
      $(printf '%s' "$rebuild_log_block" | ${pkgs.gnused}/bin/sed 's/[[:cntrl:]]/ /g')"
      fi

      echo "[Diagnose] === diagnosis for ${config.networking.hostName} (source=$log_source) ==="
      printf '%s\n' "$summary"
      echo "[Diagnose] === end diagnosis ==="

      token_file="${
        if gotifyTokenFile != null
        then gotifyTokenFile
        else ""
      }"
      if [ -n "$token_file" ] && [ -r "$token_file" ]; then
        token="$(${pkgs.gawk}/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
        if [ -n "$token" ]; then
          ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
            -F "title=nixos-upgrade failed on ${config.networking.hostName}" \
            -F "message=$summary" \
            -F "priority=8" >/dev/null || true
        fi
      fi
    '';

    smartUpgrade = pkgs.writeShellScriptBin "smart-nixos-upgrade" ''
      set -euo pipefail

      log() { echo "[SmartUpdate] $1"; }
      notify_failure() {
        local status="$1"
        local log_file="$2"
        local token_file="${gotifyTokenFile}"
        if [ -z "$token_file" ] || [ ! -r "$token_file" ]; then
          return 0
        fi
        local token
        token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
        if [ -z "$token" ]; then
          return 0
        fi
        local message_tail
        message_tail="$(/run/current-system/sw/bin/tail -n 120 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
        /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
          -F "title=nixos-upgrade failed on ${config.networking.hostName}" \
          -F "message=$message_tail" \
          -F "priority=8" >/dev/null || true
        return "$status"
      }

      log "--- STARTING SMART UPDATE SEQUENCE ---"

      # 0. AC POWER GATE (runs first - fastest check)
      ${lib.optionalString cfg.checkAcPower ''
        log "Checking AC Power..."
        AC_ONLINE=0
        for supply in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
          if [ -f "$supply/online" ]; then
            status=$(cat "$supply/online")
            if [ "$status" -eq 1 ]; then
              AC_ONLINE=1
              break
            fi
          fi
        done

        if [ "$AC_ONLINE" -eq 0 ]; then
          log "GATE FAIL: AC Power Check"
          log "  - Status: On Battery"
          log "  - Result: SKIPPING update."
          exit 0
        fi
        log "GATE PASS: AC Power Check (Plugged In)"
      ''}

      # 1. SSID Gate
      ALLOWED_SSIDS="${lib.concatStringsSep "|" cfg.checkWifi}"
      if [ -n "$ALLOWED_SSIDS" ]; then
        log "Checking Network..."

        # WAIT LOOP: Wait up to 45 seconds for NetworkManager to settle
        for i in {1..45}; do
          STATE=$(nmcli -t -f state general 2>/dev/null || echo "unknown")
          if [[ "$STATE" == "connected" ]]; then
            break
          fi
          if [ "$i" -eq 1 ]; then log "Waiting for connection (max 45s)..."; fi
          sleep 1
        done

        CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2- || echo "")

        if [ -z "$CURRENT_SSID" ]; then
          log "GATE FAIL: WiFi Check"
          log "  - Current: No connection (or timed out)"
          log "  - Result: SKIPPING update."
          exit 0
        fi

        if ! echo "$CURRENT_SSID" | grep -qE "^($ALLOWED_SSIDS)$"; then
          log "GATE FAIL: WiFi Check"
          log "  - Current: '$CURRENT_SSID'"
          log "  - Allowed: [$ALLOWED_SSIDS]"
          log "  - Result: SKIPPING update."
          exit 0
        fi
        log "GATE PASS: WiFi Check (Connected to '$CURRENT_SSID')"
      fi

      log "--- GATES PASSED. EXECUTING NIXOS REBUILD ---"
      if ${lib.boolToString useVerifiedUpdate}; then
        log "Target: verified fleet-update (${verifyCfg.writeRoot}/${verifyCfg.branch})"
      else
        log "Target Flake: ${config.system.autoUpgrade.flake}"
      fi

      log_file="$(/run/current-system/sw/bin/mktemp)"
      set +e
      if ${lib.boolToString useVerifiedUpdate}; then
        ${lib.getExe config.system.build.fleetUpdate} >"$log_file" 2>&1
      else
        ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
          --flake ${config.system.autoUpgrade.flake} \
          ${lib.concatStringsSep " " config.system.autoUpgrade.flags} \
          >"$log_file" 2>&1
      fi
      UPDATE_EXIT_CODE=$?
      set -e
      /run/current-system/sw/bin/cat "$log_file"

      if [ $UPDATE_EXIT_CODE -eq 0 ]; then
        log "--- UPDATE SUCCESS ---"
        mkdir -p /var/lib/nixos-upgrade
        date +%s > /var/lib/nixos-upgrade/last-success-timestamp

        if ${lib.boolToString cfg.rebootOnKernelUpdate}; then
          BOOTED=$(readlink -f /run/booted-system/kernel)
          NEW=$(readlink -f /nix/var/nix/profiles/system/kernel)
          if [ "$BOOTED" != "$NEW" ]; then
            log "ACTION: Kernel change detected. Rebooting system..."
            /run/current-system/sw/bin/reboot
            exit 0
          fi
        fi
      else
        log "--- UPDATE FAILED (Exit Code $UPDATE_EXIT_CODE) ---"
        log "Check journal above for nixos-rebuild errors."
        /run/current-system/sw/bin/mkdir -p /var/lib/nixos-upgrade
        # install -m 0644 so the diagnose unit (runs as a non-root user) can
        # actually read the log. Plain `cp` preserves mktemp's 0600 mode and
        # was the silent root cause of "No failure log" diagnoses (epi 2026-05-25).
        /run/current-system/sw/bin/install -m 0644 "$log_file" /var/lib/nixos-upgrade/last-failure.log || true
        ${
        if cfg.diagnose.enable
        then ""
        else ''notify_failure "$UPDATE_EXIT_CODE" "$log_file" || true''
      }
      fi

      /run/current-system/sw/bin/rm -f "$log_file"
      exit "$UPDATE_EXIT_CODE"
    '';

    laptopWrapper = pkgs.writeShellScriptBin "smart-nixos-upgrade-wrapper" ''
      set -euo pipefail

      log() { echo "[SmartUpdate] $*"; }

      # 1) Wait for logind to finish resume (bounded, no infinite hang).
      for i in $(seq 1 30); do
        pfs="$(loginctl show -p PreparingForSleep --value 2>/dev/null || true)"
        if [ -z "$pfs" ] || [ "$pfs" = "no" ]; then
          break
        fi
        [ "$i" -eq 1 ] && log "logind PreparingForSleep=yes; waiting..."
        sleep 1
      done

      INHIBIT=("${pkgs.systemd}/bin/systemd-inhibit"
        "--what=sleep:idle:handle-lid-switch"
        "--who=NixOS Upgrade"
        "--why=System update in progress"
        "--mode=block"
      )

      # 2) Acquire inhibitor and run upgrade
      "''${INHIBIT[@]}" -- ${lib.getExe smartUpgrade}

      # When we exit, the inhibitor releases and logind will handle
      # suspend automatically if the lid is still closed.
    '';
  in {
    # 1) Base autoUpgrade setup
    system.autoUpgrade = {
      enable = true;
      flake = "github:abl030/nixosconfig#${config.networking.hostName}";
      flags = [
        "--no-write-lock-file"
        "-L"
        "--option"
        "accept-flake-config"
        "true"
      ];
      dates = cfg.updateDates;
      randomizedDelaySec = "60min";
    };

    # 2) Timer wake
    systemd.timers.nixos-upgrade.timerConfig.WakeSystem = cfg.wakeOnUpdate;

    # 3) Logind: ONLY adjust lid inhibitor semantics on AC-gated hosts (i.e. laptops)
    services.logind.settings.Login = lib.mkIf cfg.checkAcPower {
      LidSwitchIgnoreInhibited = "no";
    };

    # 4) Override nixos-upgrade ExecStart:
    #    - on laptops (checkAcPower=true): wrapper (wait+inhibit)
    #    - elsewhere: just run the upgrade script (no logind dependency)
    # Order after sleep services so we only run AFTER resume completes.
    # Do NOT use Wants= here - that would TRIGGER these services to start!
    systemd.services.nixos-upgrade = {
      onFailure = lib.optional cfg.diagnose.enable "nixos-upgrade-diagnose.service";

      after = lib.mkAfter [
        "network-online.target"
        "systemd-suspend.service"
        "systemd-hibernate.service"
        "systemd-hybrid-sleep.service"
        "systemd-suspend-then-hibernate.service"
      ];

      path = with pkgs; [
        coreutils
        git
        gnugrep
        networkmanager
        gawk
        jq
        openssh
        systemd
      ];

      serviceConfig = {
        Type = "oneshot";
        # Timeout for the entire update operation (DNS check + rebuild + activation)
        # Prevents indefinite hangs from stuck activations (e.g., systemd generator bugs)
        TimeoutStartSec = cfg.timeout;
        ExecCondition = lib.optional useVerifiedUpdate "${lib.getExe config.system.build.fleetUpdate} --probe-origins";
        ExecStartPre = [
          (pkgs.writeShellScript "nixos-upgrade-net-ready" ''
            set -euo pipefail
            log() { echo "[SmartUpdate] $*"; }

            # Probe actual reachability of api.github.com, not just DNS
            # resolution. tailscaled's stub resolver answers within seconds
            # of resume-from-suspend, but the WAN route can still be down
            # for 30s+ after that — long enough to blow through the rebuild's
            # 5×15s curl retry budget. A real TLS request is the only honest
            # signal that the upcoming flake fetch will actually work.
            log "Waiting for api.github.com reachability (max 5 minutes)..."
            for i in $(seq 1 60); do
              if ${pkgs.curl}/bin/curl -sSf --max-time 5 https://api.github.com/zen >/dev/null 2>&1; then
                log "GitHub reachable."
                exit 0
              fi
              if [ "$i" -eq 1 ]; then
                log "GitHub not reachable yet; retrying every 5s..."
              fi
              sleep 5
            done

            log "GitHub unreachable after 5 minutes; skipping update."
            exit 0
          '')
          # Revalidate the GitHub PAT BEFORE the fetch. A stale token poisons
          # every github.com request with 401, so this must run before the
          # flake is resolved, not just as a post-switch activation. See #210.
          refreshAccessTokens
        ];
        ExecStart = lib.mkForce (
          if cfg.checkAcPower
          then lib.getExe laptopWrapper
          else lib.getExe smartUpgrade
        );
      };
    };

    systemd.services.nixos-upgrade-diagnose = lib.mkIf cfg.diagnose.enable {
      description = "Triage the last nixos-upgrade failure via claude -p and notify Gotify";
      serviceConfig = {
        Type = "oneshot";
        User = diagnoseUser;
        # Allow journalctl fallback when last-failure.log isn't present.
        # User= drops supplementary groups; systemd-journal grants read access
        # to /var/log/journal regardless of wheel membership.
        SupplementaryGroups = ["systemd-journal"];
        # Read the failure log written by root.
        ReadOnlyPaths = ["/var/lib/nixos-upgrade"];
        # Bounded — never longer than the failure log is interesting for.
        TimeoutStartSec = "15min";
        # Don't propagate failure: the parent unit already failed; this is just notification.
        SuccessExitStatus = ["0" "1"];
        ExecStart = diagnoseScript;
      };
    };

    # Ensure the persisted log directory exists and is readable by abl030 (the
    # diagnose unit reads it).
    systemd.tmpfiles.rules = lib.mkIf cfg.diagnose.enable [
      "d /var/lib/nixos-upgrade 0755 root root -"
    ];

    nix.gc = lib.mkIf cfg.collectGarbage {
      automatic = true;
      dates = cfg.gcDates;
      options = "--delete-older-than 3d";
    };

    services.fstrim = lib.mkIf cfg.trim {
      enable = true;
      interval = cfg.trimInterval;
    };
  });
}
