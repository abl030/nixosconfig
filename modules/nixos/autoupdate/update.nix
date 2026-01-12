{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.homelab.update;
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
  };

  config = lib.mkIf cfg.enable (let
    smartUpgrade = pkgs.writeShellScriptBin "smart-nixos-upgrade" ''
      set -euo pipefail

      log() { echo "[SmartUpdate] $1"; }

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
      log "Target Flake: ${config.system.autoUpgrade.flake}"

      ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
        --flake ${config.system.autoUpgrade.flake} \
        ${lib.concatStringsSep " " config.system.autoUpgrade.flags}

      UPDATE_EXIT_CODE=$?

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
      fi

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
      after = lib.mkAfter [
        "systemd-suspend.service"
        "systemd-hibernate.service"
        "systemd-hybrid-sleep.service"
        "systemd-suspend-then-hibernate.service"
      ];

      path = with pkgs; [
        coreutils
        gnugrep
        networkmanager
        gawk
        systemd
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.mkForce (
          if cfg.checkAcPower
          then lib.getExe laptopWrapper
          else lib.getExe smartUpgrade
        );
      };
    };

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
