# Native Kopia backup server module
# Replaces the podman-compose stack with systemd services
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
    lib.any (s: lib.hasPrefix "/mnt/mum" s) (inst.sources ++ inst.readWriteSources))
  (lib.attrValues cfg.instances);

  # Build mount dependencies for an instance
  mountDepsFor = inst: let
    allPaths = inst.sources ++ inst.readWriteSources;
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

      sources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Read-only paths to back up.";
      };

      readWriteSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Read-write paths to back up (e.g. /mnt/mum needs rw for NFS).";
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

    # /mnt/mum NFS mount — only when needed
    environment.systemPackages = lib.mkIf needsMumMount (lib.mkOrder 1600 (with pkgs; [nfs-utils]));

    boot.initrd = lib.mkIf needsMumMount {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/mum" = lib.mkIf needsMumMount {
      device = "100.100.237.21:/volumeUSB1/usbshare";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "_netdev"
        "x-systemd.requires=tailscaled.service"
        "x-systemd.after=tailscaled.service"
        "x-systemd.idle-timeout=300"
        "noatime"
        "retry=10"
      ];
    };

    # Per-instance systemd services + verify services
    systemd.services =
      (lib.mapAttrs' (name: inst:
        lib.nameValuePair "kopia-${name}" {
          description = "Kopia backup server (${name})";
          after = ["network-online.target"] ++ mountDepsFor inst;
          requires = mountDepsFor inst;
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];

          script = ''
            exec ${pkgs.kopia}/bin/kopia server start \
              --config-file=${inst.configDir}/repository.config \
              --address=0.0.0.0:${toString inst.port} \
              --insecure \
              --disable-csrf-token-checks \
              --server-username="$KOPIA_SERVER_USER" \
              --server-password="$KOPIA_SERVER_PASSWORD" \
              ${lib.optionalString (inst.overrideHostname != null) "--override-hostname=${inst.overrideHostname}"} \
              ${lib.optionalString (inst.overrideUsername != null) "--override-username=${inst.overrideUsername}"} \
              ${lib.concatStringsSep " " inst.extraArgs}
          '';
          serviceConfig = {
            Type = "simple";
            User = "kopia";
            Group = "kopia";
            EnvironmentFile = [config.sops.secrets."kopia/env".path];
            Restart = "on-failure";
            RestartSec = 10;
            ProtectHome = true;
            NoNewPrivileges = true;
          };
        })
      cfg.instances)
      // (lib.mapAttrs' (name: inst:
        lib.nameValuePair "kopia-verify-${name}" {
          description = "Kopia snapshot verify for ${name}";
          after = ["kopia-${name}.service"];
          requires = ["kopia-${name}.service"];
          serviceConfig = {
            Type = "oneshot";
            User = "kopia";
            Group = "kopia";
            ExecStart = mkVerifyScript {inherit name inst;};
          };
        })
      cfg.instances);

    systemd.timers = lib.mapAttrs' (name: _inst:
      lib.nameValuePair "kopia-verify-${name}" {
        description = "Daily Kopia verify for ${name}";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-* 04:00:00";
          Persistent = true;
          Unit = "kopia-verify-${name}.service";
        };
      })
    cfg.instances;

    # localProxy + monitoring
    homelab = {
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
