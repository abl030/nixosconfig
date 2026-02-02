# Scheduled rsync of Operations & Production from work Z: drive to home NFS
# Runs nightly, mirrors source with deletes, only copies changed files
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.opsSync;
  src = "/mnt/z/Operations & Production/";
  dest = "/mnt/data/Life/Cullen/Ops Backup/";
  gotifyCfg = config.homelab.gotify;
  gotifyTokenFile = config.sops.secrets."gotify/token".path or null;
in {
  options.homelab.mounts.opsSync = {
    enable = mkEnableOption "Scheduled rsync of Operations & Production to home NFS";

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 21:00:00";
      description = "Systemd calendar expression for when to run the sync";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.ops-sync = {
      description = "Rsync Operations & Production to home NFS";
      after = ["network-online.target" "mnt-z.automount" "mnt-data.automount"];
      wants = ["network-online.target"];
      restartIfChanged = false;
      path = [pkgs.rsync pkgs.coreutils pkgs.util-linux pkgs.curl];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "ops-sync" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          log() { logger -t ops-sync "$1"; echo "$1"; }

          notify_failure() {
            local msg="$1"
            if [ -n "${gotifyTokenFile}" ] && [ -r "${gotifyTokenFile}" ]; then
              token=$(${pkgs.gawk}/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "${gotifyTokenFile}")
              if [ -n "$token" ]; then
                curl -fsS -X POST "${gotifyCfg.endpoint}/message?token=$token" \
                  -F "title=ops-sync failed on ${config.networking.hostName}" \
                  -F "message=$msg" \
                  -F "priority=8" >/dev/null || true
              fi
            fi
          }

          trap 'notify_failure "Sync failed at line $LINENO"' ERR

          # Verify source is accessible
          if [ ! -d "${src}" ]; then
            log "ERROR: Source ${src} not accessible, aborting"
            notify_failure "Source ${src} not accessible"
            exit 1
          fi

          # Verify destination is accessible
          if [ ! -d "${dest}" ]; then
            log "ERROR: Destination ${dest} not accessible, aborting"
            notify_failure "Destination ${dest} not accessible"
            exit 1
          fi

          log "Starting sync from Z: Operations & Production to home NFS"

          rsync -rlptv \
            --delete \
            --exclude='Thumbs.db' \
            --exclude='.stfolder' \
            --exclude='desktop.ini' \
            --exclude='~$*' \
            --timeout=300 \
            "${src}" "${dest}"

          log "Sync completed successfully"
        '';

        # Run as root to handle both drvfs and NFS permissions
        User = "root";

        # Restart on transient failures (network blip etc)
        Restart = "on-failure";
        RestartSec = "5min";
        RestartMaxDelaySec = "30min";

        # Generous timeout for large syncs over Tailscale
        TimeoutStartSec = "2h";
      };
    };

    systemd.timers.ops-sync = {
      description = "Timer for Operations & Production sync";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "15min";
      };
    };
  };
}
