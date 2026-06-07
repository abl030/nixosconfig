# Native Kopia backup server module
# Replaces the podman-compose stack with systemd services
#
# See docs/wiki/services/kopia.md for the full backup architecture:
# Object Lock policy, Wasabi IAM scoping, secret handling, snapshot
# policies, and the key rotation playbook.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.kopia;

  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;

  # Reconciliation script — makes `inst.sources` the source of truth
  # for what's registered in the running kopia daemon. Runs once on every
  # rebuild via `kopia-<name>-source-sync.service`. Idempotent.
  #
  # See #255 for the motivating incident (12 weeks of silent backup loss
  # because the 2026-02-26 migration's `sources = ["/mnt/data"]` was
  # never registered with the new daemon, and the orphaned per-subdir
  # sources lost their schedules).
  #
  # Logic:
  #   1. Wait up to 90s for the daemon to be reachable.
  #   2. Query /api/v1/sources for the current source list.
  #   3. For every path in inst.sources:
  #        - If the source key isn't registered, POST /api/v1/sources/upload
  #          (auto-creates + triggers initial snapshot).
  #        - Always PUT /api/v1/policy with the configured timeOfDay.
  #   4. For every registered source NOT in inst.sources, log a WARNING
  #      to stderr. Do not auto-remove — that's destructive.
  mkSourceSyncScript = {
    name,
    inst,
  }:
    pkgs.writeShellScript "kopia-${name}-source-sync" ''
      set -uo pipefail

      base="http://127.0.0.1:${toString inst.port}"
      hour="${toString inst.snapshotScheduleHour}"
      min="${toString inst.snapshotScheduleMinute}"

      auth_user="''${KOPIA_SERVER_USER:?}"
      auth_pass="''${KOPIA_SERVER_PASSWORD:?}"

      override_host="${
        if inst.overrideHostname != null
        then inst.overrideHostname
        else "doc2"
      }"
      override_user="${
        if inst.overrideUsername != null
        then inst.overrideUsername
        else "kopia"
      }"

      # Wait for daemon ready (HTTP 200 from /api/v1/repo/status).
      max_wait=90
      waited=0
      while ! ${pkgs.curl}/bin/curl -fsS --max-time 3 \
        -u "$auth_user:$auth_pass" \
        "$base/api/v1/repo/status" >/dev/null 2>&1; do
        if [ "$waited" -ge "$max_wait" ]; then
          echo "kopia-${name}-source-sync: daemon not reachable after ''${max_wait}s — aborting" >&2
          exit 1
        fi
        sleep 3
        waited=$((waited + 3))
      done

      declared_paths=(${
        lib.concatMapStringsSep " "
        (s: lib.escapeShellArg s)
        inst.sources
      })

      # Current registered paths (for orphan detection).
      current_json=$(${pkgs.curl}/bin/curl -fsS --max-time 30 -u "$auth_user:$auth_pass" "$base/api/v1/sources")
      current_paths=$(printf '%s' "$current_json" | ${pkgs.jq}/bin/jq -r '.sources[].source.path')

      # NOTE: use `printf '%s'`, NOT `<<<` — bash here-strings add a
      # trailing newline, which jq's @uri then URL-encodes as %0A.
      # kopia accepts the encoded form and CREATES A SOURCE with a
      # literal \n in the path. (Bit me on first deploy.)
      url_encode() {
        printf '%s' "$1" | ${pkgs.jq}/bin/jq -sRr @uri
      }

      # Per-source ignore rules (kopia policy files.ignore), keyed by source
      # path. Generated from inst.sourceExcludes so exclusions stay declarative
      # in nix, not as a .kopiaignore file inside the backed-up tree.
      declare -A ignore_json=(
        ${
        lib.concatStringsSep "\n        "
        (lib.mapAttrsToList
          (p: rules: "[${lib.escapeShellArg p}]=${lib.escapeShellArg (builtins.toJSON rules)}")
          inst.sourceExcludes)
      }
      )

      # PUT policy with the configured schedule plus any per-source ignore
      # rules (idempotent; works for both new and existing sources).
      set_policy() {
        local path="$1"
        local encp body
        encp=$(url_encode "$path")
        body="{\"scheduling\":{\"timeOfDay\":[{\"hour\":$hour,\"min\":$min}],\"runMissed\":true}"
        if [ -n "''${ignore_json[$path]:-}" ]; then
          body="$body,\"files\":{\"ignore\":''${ignore_json[$path]}}"
        fi
        body="$body}"
        ${pkgs.curl}/bin/curl -fsS --max-time 30 -u "$auth_user:$auth_pass" \
          -X PUT \
          -H 'content-type: application/json' \
          --data "$body" \
          "$base/api/v1/policy?host=$override_host&userName=$override_user&path=$encp" \
          >/dev/null
      }

      # Trigger upload (creates source + snapshot on first call;
      # idempotent thereafter — kopia just notes the source is busy or
      # queues another snapshot).
      trigger_upload() {
        local path="$1"
        local encp
        encp=$(url_encode "$path")
        ${pkgs.curl}/bin/curl -fsS --max-time 30 -u "$auth_user:$auth_pass" \
          -X POST \
          "$base/api/v1/sources/upload?host=$override_host&userName=$override_user&path=$encp" \
          >/dev/null
      }

      missing=0
      for path in "''${declared_paths[@]}"; do
        if printf '%s\n' "$current_paths" | ${pkgs.gnugrep}/bin/grep -Fxq "$path"; then
          echo "kopia-${name}-source-sync: source ALREADY registered: $path — refreshing policy"
          set_policy "$path" || echo "  (policy update failed for $path)" >&2
        else
          echo "kopia-${name}-source-sync: source MISSING: $path — creating + triggering initial snapshot"
          set_policy "$path" || echo "  (policy create failed for $path)" >&2
          trigger_upload "$path" || echo "  (upload trigger failed for $path)" >&2
          missing=$((missing + 1))
        fi
      done

      # Orphan detection — sources in the daemon but not in nix.
      orphans=0
      for path in $current_paths; do
        if ! printf '%s\n' "''${declared_paths[@]}" | ${pkgs.gnugrep}/bin/grep -Fxq "$path"; then
          echo "kopia-${name}-source-sync: WARNING orphan source in daemon (not in nix): $path" >&2
          orphans=$((orphans + 1))
        fi
      done

      echo "kopia-${name}-source-sync: reconcile complete — declared=''${#declared_paths[@]} missing=$missing orphans=$orphans"
    '';

  # Generate a verify script for a kopia instance
  mkVerifyScript = {
    name,
    inst,
  }:
    pkgs.writeShellScript "kopia-verify-${name}" ''
      set -euo pipefail

      echo "=== Kopia verify starting for ${name} ==="
      echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      start_epoch=$(date +%s)
      exit_code=0
      output=$(${pkgs.kopia}/bin/kopia snapshot verify \
        --config-file=${inst.configDir}/repository.config \
        --verify-files-percent=${toString inst.verifyPercent} \
        --parallel=2 2>&1) \
        || exit_code=$?
      end_epoch=$(date +%s)

      echo "$output"

      elapsed=$((end_epoch - start_epoch))
      elapsed_min=$((elapsed / 60))

      # Extract the "Finished processing" summary line from kopia output
      finished_line=$(echo "$output" | ${pkgs.gnugrep}/bin/grep -i '^Finished processing' | tail -1 || true)

      # Parse "Read N files (X.Y MB/GB/TB)" from the finished line
      read_amount=""
      read_unit=""
      if [ -n "$finished_line" ]; then
        read_amount=$(echo "$finished_line" | ${pkgs.gnused}/bin/sed -n 's/.*Read [0-9]* files (\([0-9.]*\) \([A-Z]*\)).*/\1/p')
        read_unit=$(echo "$finished_line" | ${pkgs.gnused}/bin/sed -n 's/.*Read [0-9]* files ([0-9.]* \([A-Z]*\)).*/\1/p')
      fi

      # Calculate bandwidth if we have bytes and elapsed time
      bandwidth_msg=""
      if [ -n "$read_amount" ] && [ "$elapsed" -gt 0 ]; then
        case "$read_unit" in
          B)  multiplier="0.000001";;
          KB) multiplier="0.001";;
          MB) multiplier="1";;
          GB) multiplier="1024";;
          TB) multiplier="1048576";;
          *)  multiplier="1";;
        esac
        read_mb=$(${pkgs.bc}/bin/bc <<< "scale=1; $read_amount * $multiplier")
        mb_per_sec=$(${pkgs.bc}/bin/bc <<< "scale=1; $read_mb / $elapsed")
        mbps=$(${pkgs.bc}/bin/bc <<< "scale=0; $mb_per_sec * 8")
        bandwidth_msg="bandwidth=''${read_amount}''${read_unit} in ''${elapsed}s = ''${mb_per_sec} MB/s (~''${mbps} Mbps)"
      fi

      echo "=== Kopia verify finished for ${name} ==="
      echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) exit_code=$exit_code elapsed_seconds=$elapsed elapsed_minutes=$elapsed_min"
      if [ -n "$finished_line" ]; then
        echo "summary=$finished_line"
      fi
      if [ -n "$bandwidth_msg" ]; then
        echo "$bandwidth_msg"
      fi

      if [ "$exit_code" -ne 0 ]; then
        token_file="${gotifyTokenFile}"
        if [ -n "$token_file" ] && [ -r "$token_file" ]; then
          token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
          if [ -n "$token" ]; then
            /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
              -F "title=kopia-verify failed: ${name} on ${config.networking.hostName}" \
              -F "message=Verify exited with code $exit_code. Check journalctl -u kopia-verify-${name}." \
              -F "priority=8" >/dev/null || true
          fi
        fi
        exit "$exit_code"
      fi
    '';

  # Check if any instance references /mnt/mum
  needsMumMount = lib.any (inst:
    lib.any (s: lib.hasPrefix "/mnt/mum" s) (inst.sources ++ inst.repositoryMounts))
  (lib.attrValues cfg.instances);

  # Build mount dependencies for an instance
  mountDepsFor = inst: let
    allPaths = inst.sources ++ inst.repositoryMounts;
    hasMntData = lib.any (s: lib.hasPrefix "/mnt/data" s) allPaths;
    hasMntMum = lib.any (s: lib.hasPrefix "/mnt/mum" s) allPaths;
    hasMntVirtio = lib.any (s: lib.hasPrefix "/mnt/virtio" s) allPaths;
  in
    lib.optional hasMntData "mnt-data.mount"
    ++ lib.optional hasMntMum "mnt-mum.automount"
    ++ lib.optional hasMntVirtio "mnt-virtio.mount";

  instanceModule = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.port;
        description = "Listen port for kopia server.";
      };

      configDir = lib.mkOption {
        type = lib.types.str;
        description = "Directory containing repository.config for this instance.";
      };

      # Source vs repository: kopia "sources" are paths kopia walks and snapshots
      # (read-only — kopia never modifies the data it's backing up).
      # kopia "repositories" are destinations where kopia writes blob/index files
      # (read-write — kopia owns these). For filesystem-type repos the repo lives
      # on a mounted path that must be brought up before kopia starts and watched
      # for staleness. The two roles look identical to the host config (both are
      # just paths) but failure modes diverge — a stale source means a snapshot
      # might miss data; a stale repo means a snapshot can't land at all. Don't
      # mix them up.
      sources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Read-only source paths kopia walks and snapshots. Mounts referenced
          here are added as systemd dependencies so kopia waits for them at
          startup. Use `repositoryMounts` for the destination side.
        '';
      };

      sourceExcludes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = {};
        example = {"/mnt/data/Life" = ["/Photos/library" "/Tech/Backups/UnraidUSB"];};
        description = ''
          Per-source kopia ignore rules, keyed by source path (which must also
          appear in `sources`). Each rule is a gitignore-style pattern resolved
          against that source's root — a leading `/` anchors to the source dir.
          The reconciler writes these into the source's kopia policy
          (`files.ignore`) on every rebuild, keeping exclusions declarative here
          rather than as a `.kopiaignore` file in the backed-up tree. Sources not
          listed here get no ignore rules.
        '';
      };

      repositoryMounts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Mounted filesystem paths hosting kopia repositories that this instance
          writes to (i.e. the destination side — where kopia stores its
          `kopia.repository`, indexes, and blob packs). Kopia needs read-write
          access; mount staleness here is more catastrophic than a stale source
          because snapshots can't land. Triggers the same systemd dependency
          wiring as `sources`. Currently used for `/mnt/mum` (mum's Synology
          over Tailscale).
        '';
      };

      proxyHost = lib.mkOption {
        type = lib.types.str;
        description = "Domain name for nginx reverse proxy (e.g. kopiaphotos.ablz.au).";
      };

      verifyPercent = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Percentage of files to verify in daily snapshot verify.";
      };

      overrideHostname = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override hostname kopia uses for source matching (for container migration).";
      };

      overrideUsername = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override username kopia uses for source matching (for container migration).";
      };

      runAsRoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run this instance as root (needed when NFS repo has restrictive perms).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional arguments for kopia server start.";
      };

      snapshotScheduleHour = lib.mkOption {
        type = lib.types.int;
        default = 6;
        description = ''
          Hour-of-day (0-23, local time) the source-reconciler sets as
          the kopia snapshot schedule for every source declared in
          `sources`. Used by `kopia-<name>-source-sync.service` on
          every rebuild. See #255 for the migration that motivated
          declarative source registration.
        '';
      };

      snapshotScheduleMinute = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Minute-of-hour for the snapshot schedule.";
      };
    };
  };

  kopiaMonitoringSecret = "kopia-monitoring/env";
in {
  options.homelab.services.kopia = {
    enable = lib.mkEnableOption "Kopia backup server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kopia";
      description = "Base directory for kopia state.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceModule;
      default = {};
      description = "Kopia server instances to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Static user — needs NFS access via users group
    users.users.kopia = {
      isSystemUser = true;
      group = "kopia";
      home = cfg.dataDir;
      extraGroups = ["users"];
    };
    users.groups.kopia = {};

    # Sops secrets: kopia env (KOPIA_PASSWORD, KOPIA_SERVER_USER, KOPIA_SERVER_PASSWORD)
    sops.secrets."kopia/env" = {
      sopsFile = config.homelab.secrets.sopsFile "kopia.env";
      format = "dotenv";
      owner = "kopia";
      mode = "0400";
    };

    # Monitoring secret for Uptime Kuma json-query auth
    sops.secrets.${kopiaMonitoringSecret} = {
      sopsFile = config.homelab.secrets.sopsFile "kopia.env";
      format = "dotenv";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    # /mnt/mum is the kopia *repository* destination (Mum's Synology over
    # Tailscale), NOT a source path. The actual fileSystems definition lives
    # in modules/nixos/services/mounts/mum-nfs.nix — kopia just opts in here
    # whenever an instance references /mnt/mum.

    # Per-instance systemd services + verify services
    systemd.services =
      (lib.mapAttrs' (name: inst:
        lib.nameValuePair "kopia-${name}" {
          description = "Kopia backup server (${name})";
          after = ["network-online.target"] ++ mountDepsFor inst;
          requires = mountDepsFor inst;
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];

          # CSRF protection trade-off: --disable-csrf-token-checks is on because
          # kopia's CSRF middleware is all-or-nothing for the standard /api/v1
          # endpoints. With it enabled, programmatic monitoring (uptime-kuma's
          # json-query on /api/v1/sources) breaks — kopia rejects with
          # "Invalid or missing CSRF token" even with valid basic auth.
          # Threat model with the flag on but loopback bind + Object Lock:
          # - "any local process" attack → loopback bind reduces this to
          #   root-on-doc2 only, which is game-over regardless
          # - "XSS-on-UI fires CSRF" → still real, but Object Lock Compliance
          #   on the Wasabi side physically blocks the catastrophic outcomes
          #   (delete snapshots, shorten retention, wipe repo). The damage a
          #   CSRF attack can actually do is reduced to "trigger a wrong
          #   snapshot" or "change UI preferences" — annoying, not data-loss.
          # See docs/wiki/services/kopia.md "Network exposure" for full reasoning.
          script = ''
            exec ${pkgs.kopia}/bin/kopia server start \
              --config-file=${inst.configDir}/repository.config \
              --address=127.0.0.1:${toString inst.port} \
              --insecure \
              --disable-csrf-token-checks \
              --server-username="$KOPIA_SERVER_USER" \
              --server-password="$KOPIA_SERVER_PASSWORD" \
              ${lib.optionalString (inst.overrideHostname != null) "--override-hostname=${inst.overrideHostname}"} \
              ${lib.optionalString (inst.overrideUsername != null) "--override-username=${inst.overrideUsername}"} \
              ${lib.concatStringsSep " " inst.extraArgs}
          '';
          environment.HOME = cfg.dataDir;
          serviceConfig = {
            Type = "simple";
            User =
              if inst.runAsRoot
              then "root"
              else "kopia";
            Group =
              if inst.runAsRoot
              then "root"
              else "kopia";
            EnvironmentFile = [config.sops.secrets."kopia/env".path];
            Restart = "on-failure";
            RestartSec = 10;
            ProtectHome = lib.mkIf (!inst.runAsRoot) true;
            NoNewPrivileges = true;
          };
        })
      cfg.instances)
      // (lib.mapAttrs' (name: inst:
          lib.nameValuePair "kopia-verify-${name}" {
            description = "Kopia snapshot verify for ${name}";
            after = ["kopia-${name}.service"];
            requires = ["kopia-${name}.service"];
            environment.HOME = cfg.dataDir;
            serviceConfig = {
              Type = "oneshot";
              User =
                if inst.runAsRoot
                then "root"
                else "kopia";
              Group =
                if inst.runAsRoot
                then "root"
                else "kopia";
              EnvironmentFile = [config.sops.secrets."kopia/env".path];
              ExecStart = mkVerifyScript {inherit name inst;};
            };
          })
        cfg.instances
        // (lib.mapAttrs' (name: inst:
          lib.nameValuePair "kopia-${name}-source-sync" {
            description = "Reconcile kopia ${name} declared sources with the daemon";
            after = ["kopia-${name}.service"];
            requires = ["kopia-${name}.service"];
            wantedBy = ["multi-user.target"];
            environment.HOME = cfg.dataDir;
            # Re-run on every deploy where the source list or schedule
            # changes. The script itself is idempotent so re-running on
            # unrelated rebuilds is cheap (one PUT per source = ~50 ms each).
            restartTriggers = [
              (builtins.toJSON {
                inherit (inst) sources sourceExcludes snapshotScheduleHour snapshotScheduleMinute;
              })
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              # Backstop: per-curl --max-time bounds the reconcile, but never
              # let a busy daemon (mid-upload, API stalled) hang a deploy
              # forever — fail the oneshot so switch-to-configuration proceeds.
              # The source registration that matters already happened.
              TimeoutStartSec = 600;
              User =
                if inst.runAsRoot
                then "root"
                else "kopia";
              Group =
                if inst.runAsRoot
                then "root"
                else "kopia";
              EnvironmentFile = [config.sops.secrets."kopia/env".path];
              ExecStart = mkSourceSyncScript {inherit name inst;};
            };
          })
        cfg.instances));

    systemd.timers = lib.mapAttrs' (name: _inst:
      lib.nameValuePair "kopia-verify-${name}" {
        description = "Daily Kopia verify for ${name}";
        wantedBy = ["timers.target"];
        timerConfig = {
          # 05:30 sits well after doc2's nixos-upgrade window closes
          # (updateDates="04:00" + randomizedDelaySec=60min → window
          # nominally ends 05:00). An upgrade that fires at 04:59 still
          # needs time to actually run — verify after upgrade so we
          # also catch any post-upgrade breakage; the 30min gap absorbs
          # the upgrade's runtime plus any tailscale/kopia cascade
          # settling.
          OnCalendar = "*-*-* 05:30:00";
          Persistent = true;
          Unit = "kopia-verify-${name}.service";
        };
      })
    cfg.instances;

    homelab = {
      monitoring = {
        secretEnvFiles = [
          config.sops.secrets.${kopiaMonitoringSecret}.path
        ];

        monitors =
          # HTTPS availability monitors (accept 401).
          # Same `timeout = 180` and `maxretries = 25` rationale as the
          # Backup probe below: kopia's HTTP listener stalls under the
          # repository lock during full maintenance, so the default 48s
          # Kuma timeout would trip on every maintenance window.
          (lib.mapAttrsToList (name: inst: {
              name = "Kopia ${name}";
              url = "https://${inst.proxyHost}/";
              acceptedStatusCodes = ["200-299" "300-399" "401"];
              interval = 300;
              timeout = 180;
              maxretries = 25;
            })
            cfg.instances)
          ++
          # JSON-query backup health monitors.
          #
          # `timeout = 180` and `maxretries = 25` exist to absorb kopia's
          # daily full-maintenance window. Full maintenance (GC + epoch
          # compaction + content sweep) holds the repository lock for
          # 10-15 min on a 1.5 TB repo; /api/v1/sources blocks behind
          # that lock and Kuma's default 48s timeout trips. With 180s
          # per-probe timeout each individual probe survives most lock
          # waits; 25 retries × 60s = 25 min of continuous failure
          # before paging, comfortably above observed 12-min maintenance
          # but below "service genuinely broken" thresholds.
          #
          # Real backup failures are caught by the errorPatterns alerts
          # below (Kopia <name> repository broken / verify failed) which
          # read journald instead of poking the busy API.
          (lib.mapAttrsToList (name: inst: {
              name = "Kopia ${name} Backup";
              type = "json-query";
              url = "http://localhost:${toString inst.port}/api/v1/sources";
              basicAuthUserEnv = "KOPIA_SERVER_USER";
              basicAuthPassEnv = "KOPIA_SERVER_PASSWORD";
              jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0])";
              expectedValue = "0";
              interval = 300;
              timeout = 180;
              maxretries = 25;
            })
            cfg.instances);

        # See #253 audit + rules-doc "Per-service errorPatterns".
        # Excludes the chronic `broken pipe` / `error encoding response`
        # noise from kopia's web UI clients — we want repository-broken
        # signals only.
        errorPatterns = [
          # `threshold = 0` on every kopia pattern: these are single-shot
          # terminal errors logged exactly once after kopia exhausts its
          # internal retry budget (25 retries × backoff = many minutes).
          # By the time the line lands in journald the failure is real and
          # sustained — no reason to require a 2nd occurrence to page.
          {
            name = "Kopia mum repository broken";
            unit = "kopia-mum.service";
            # `despite N retries` is the post-backoff signature when
            # the NFS dest is gone or the repo is unreachable.
            pattern = "(?i)unable to (?:write|read).*despite \\d+ retries|cannot open storage|backup failed";
            severity = "critical";
            summary = "kopia-mum backup is unable to write";
            threshold = 0;
          }
          {
            name = "Kopia photos repository broken";
            unit = "kopia-photos.service";
            # Wasabi/DNS outage class. `refresh error ... despite N
            # retries` is the post-backoff signature.
            pattern = "(?i)refresh error.*despite \\d+ retries|cannot open storage";
            severity = "critical";
            summary = "kopia-photos backup cannot reach repository";
            threshold = 0;
          }
          {
            name = "Kopia mum verify failed";
            unit = "kopia-verify-mum.service";
            pattern = "(?i)unable to open repository|verification failed|Temporary failure in name resolution";
            severity = "warning";
            summary = "kopia-mum integrity verification did not run";
            threshold = 0;
          }
          {
            name = "Kopia photos verify failed";
            unit = "kopia-verify-photos.service";
            pattern = "(?i)unable to open repository|verification failed|Temporary failure in name resolution";
            severity = "warning";
            summary = "kopia-photos integrity verification did not run";
            threshold = 0;
          }
        ];

        # Stale-snapshot deep probe per kopia instance — see #254.
        # Catches the "backups stopped silently" class: kopia is up, the
        # repository is reachable, but no new snapshot has landed within
        # `KOPIA_MAX_AGE_HOURS`. Default 36h covers the daily 06:00
        # schedule with 12h slack for slow runs / weekend skips.
        deepProbes =
          lib.mapAttrsToList (name: inst: {
            name = "Kopia ${name} freshness";
            command = "${pkgs.callPackage ./probes/check-kopia-fresh.nix {}}/bin/check-kopia-fresh";
            interval = "1h";
            # Headroom over the 1h cadence so on-time pushes don't race Kuma's
            # deadline and false-flap DOWN — same boundary-race bug fixed for the
            # immich/musicbrainz probes (2026-06-05 RCA, lgtm-stack.md). 4500s = 1h + 15m.
            intervalSecs = 4500;
            # Bumped from default 60s so the probe's curl (now 250s)
            # has headroom to wait out kopia's full-maintenance lock.
            timeout = "300s";
            serviceConfig = {
              Environment = [
                "KOPIA_BASE_URL=http://localhost:${toString inst.port}"
                "KOPIA_AUTH_FILE=${config.sops.secrets.${kopiaMonitoringSecret}.path}"
                "KOPIA_MAX_AGE_HOURS=36"
              ];
            };
          })
          cfg.instances;
      };

      mounts.mumNfs.enable = lib.mkIf needsMumMount true;

      # NFS watchdog — restart kopia instance if its NFS paths go stale.
      # Probe the path more likely to flake: /mnt/mum (Tailscale → mum's
      # residential Synology) ranks above /mnt/data (LAN → tower). The
      # single-path nfsWatchdog can't probe both, so we pick the more
      # failure-prone one and rely on kopia's own errorCount monitor to
      # catch the rarer /mnt/data flake.
      nfsWatchdog = lib.mapAttrs' (name: inst: let
        allPaths = inst.sources ++ inst.repositoryMounts;
        hasMntMum = lib.any (s: lib.hasPrefix "/mnt/mum" s) allPaths;
        hasMntData = lib.any (s: lib.hasPrefix "/mnt/data" s) allPaths;
      in
        lib.nameValuePair "kopia-${name}" {
          path =
            if hasMntMum
            then "/mnt/mum"
            else if hasMntData
            then "/mnt/data"
            else builtins.head allPaths;
        })
      (lib.filterAttrs (_name: inst: (inst.sources ++ inst.repositoryMounts) != []) cfg.instances);

      localProxy.hosts =
        lib.mapAttrsToList (_name: inst: {
          host = inst.proxyHost;
          inherit (inst) port;
        })
        cfg.instances;
    };
  };
}
