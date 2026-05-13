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
  in
    lib.optional hasMntData "mnt-data.mount"
    ++ lib.optional hasMntMum "mnt-mum.automount";

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
    homelab.monitoring.secretEnvFiles = [
      config.sops.secrets.${kopiaMonitoringSecret}.path
    ];

    # /mnt/mum is the kopia *repository* destination (Mum's Synology over
    # Tailscale), NOT a source path. The actual fileSystems definition lives
    # in modules/nixos/services/mounts/mum-nfs.nix — kopia just opts in here
    # whenever an instance references /mnt/mum.
    homelab.mounts.mumNfs.enable = lib.mkIf needsMumMount true;

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
      cfg.instances);

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

    # localProxy + monitoring + NFS watchdog
    homelab = {
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

      monitoring.monitors =
        # HTTPS availability monitors (accept 401)
        (lib.mapAttrsToList (name: inst: {
            name = "Kopia ${name}";
            url = "https://${inst.proxyHost}/";
            acceptedStatusCodes = ["200-299" "300-399" "401"];
          })
          cfg.instances)
        ++
        # JSON-query backup health monitors
        (lib.mapAttrsToList (name: inst: {
            name = "Kopia ${name} Backup";
            type = "json-query";
            url = "http://localhost:${toString inst.port}/api/v1/sources";
            basicAuthUserEnv = "KOPIA_SERVER_USER";
            basicAuthPassEnv = "KOPIA_SERVER_PASSWORD";
            jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0])";
            expectedValue = "0";
            interval = 300;
          })
          cfg.instances);
    };
  };
}
