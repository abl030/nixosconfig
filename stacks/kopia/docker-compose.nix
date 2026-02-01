{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "kopia-stack";

  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;
  inherit (config.homelab) user userHome;
  userUid = let
    uid = config.users.users.${user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;

  mkVerifyScript = {
    containerName,
    label,
    verifyPercent ? "5",
  }:
    pkgs.writeShellScript "kopia-verify-${containerName}" ''
      set -euo pipefail

      echo "=== Kopia verify starting for ${label} ==="
      echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      start_epoch=$(date +%s)
      exit_code=0
      output=$(/run/current-system/sw/bin/runuser -u ${user} -- \
        ${pkgs.podman}/bin/podman exec ${containerName} \
        kopia snapshot verify --verify-files-percent=${verifyPercent} --parallel=2 2>&1) \
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
        # Convert to MB for calculation
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

      echo "=== Kopia verify finished for ${label} ==="
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
              -F "title=kopia-verify failed: ${label} on ${config.networking.hostName}" \
              -F "message=Verify exited with code $exit_code. Check journalctl -u kopia-verify-${containerName}." \
              -F "priority=8" >/dev/null || true
          fi
        fi
        exit "$exit_code"
      fi
    '';

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "kopia-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "kopia.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  # Use automount (not mount) for mnt-mum - same as old Docker service
  # Don't include /mnt/mum in requiresMounts as that adds RequiresMountsFor which
  # creates a hard dependency on the actual mount unit instead of automount
  dependsOn = [
    "network-online.target"
    "mnt-data.mount"
    "mnt-mum.automount"
  ];
  kopiaMonitoringSecret = "kopia-monitoring/env";
in
  lib.mkMerge [
    {
      sops.secrets.${kopiaMonitoringSecret} = {
        sopsFile = encEnv;
        format = "dotenv";
        owner = "root";
        group = "root";
        mode = "0400";
      };
      homelab.monitoring.secretEnvFiles = [
        config.sops.secrets.${kopiaMonitoringSecret}.path
      ];
    }
    (podman.mkService {
      inherit stackName;
      description = "Kopia Podman Compose Stack";
      projectName = "kopia";
      inherit composeFile;
      inherit envFiles;
      stackHosts = [
        {
          host = "kopiaphotos.ablz.au";
          port = 51515;
        }
        {
          host = "kopiamum.ablz.au";
          port = 51516;
        }
      ];
      stackMonitors = [
        {
          name = "Kopia Photos";
          url = "https://kopiaphotos.ablz.au/";
          acceptedStatusCodes = ["200-299" "300-399" "401"];
        }
        {
          name = "Kopia Mum";
          url = "https://kopiamum.ablz.au/";
          acceptedStatusCodes = ["200-299" "300-399" "401"];
        }
        {
          name = "Kopia Photos Backup";
          type = "json-query";
          url = "http://localhost:51515/api/v1/sources";
          basicAuthUserEnv = "KOPIA_SERVER_USER";
          basicAuthPassEnv = "KOPIA_SERVER_PASSWORD";
          jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0])";
          expectedValue = "0";
          interval = 300;
        }
        {
          name = "Kopia Mum Backup";
          type = "json-query";
          url = "http://localhost:51516/api/v1/sources";
          basicAuthUserEnv = "KOPIA_SERVER_USER";
          basicAuthPassEnv = "KOPIA_SERVER_PASSWORD";
          jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0])";
          expectedValue = "0";
          interval = 300;
        }
      ];
      # Only require /mnt/data - mnt-mum is handled via automount dependency above
      requiresMounts = ["/mnt/data"];
      wants = dependsOn;
      after = dependsOn;
      firewallPorts = [];
    })
    {
      systemd = {
        services = {
          kopia-verify-photos = {
            description = "Kopia snapshot verify for kopiaphotos";
            after = ["${stackName}.service"];
            requires = ["${stackName}.service"];
            restartIfChanged = false;
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "HOME=${userHome}"
                "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString userUid}/bus"
              ];
              ExecStart = mkVerifyScript {
                containerName = "kopiaphotos";
                label = "Kopia Photos";
              };
            };
          };

          kopia-verify-mum = {
            description = "Kopia snapshot verify for kopiamum";
            after = ["${stackName}.service"];
            requires = ["${stackName}.service"];
            restartIfChanged = false;
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "HOME=${userHome}"
                "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString userUid}/bus"
              ];
              ExecStart = mkVerifyScript {
                containerName = "kopiamum";
                label = "Kopia Mum";
                verifyPercent = "1";
              };
            };
          };
        };

        timers = {
          kopia-verify-photos = {
            description = "Daily Kopia verify for kopiaphotos";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = "*-*-* 04:00:00";
              Persistent = true;
              Unit = "kopia-verify-photos.service";
            };
          };

          kopia-verify-mum = {
            description = "Daily Kopia verify for kopiamum";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = "*-*-* 06:00:00";
              Persistent = true;
              Unit = "kopia-verify-mum.service";
            };
          };
        };
      };
    }
  ]
