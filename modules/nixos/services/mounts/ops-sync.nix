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

          MAX_RETRIES=5
          RETRY_INTERVAL=60

          log() { logger -t ops-sync "$1"; echo "$1"; }

          notify() {
            local title="$1" msg="$2" priority="''${3:-8}"
            if [ -n "${gotifyTokenFile}" ] && [ -r "${gotifyTokenFile}" ]; then
              token=$(${pkgs.gawk}/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "${gotifyTokenFile}")
              if [ -n "$token" ]; then
                curl -fsS -X POST "${gotifyCfg.endpoint}/message?token=$token" \
                  -F "title=$title" \
                  -F "message=$msg" \
                  -F "priority=$priority" >/dev/null || true
              fi
            fi
          }

          trap 'notify "ops-sync failed on ${config.networking.hostName}" "Sync failed at line $LINENO"' ERR

          # Wait for source with retries
          attempt=0
          while [ ! -d "${src}" ]; do
            attempt=$((attempt + 1))
            if [ "$attempt" -gt "$MAX_RETRIES" ]; then
              log "Source ${src} not available after $MAX_RETRIES attempts — giving up"
              notify \
                "ops-sync skipped on ${config.networking.hostName}" \
                "Source ${src} not available after $MAX_RETRIES attempts. Drive offline or VPN down — will try again next scheduled run." \
                5
              exit 0
            fi
            log "Source ${src} not available (attempt $attempt/$MAX_RETRIES), retrying in ''${RETRY_INTERVAL}s..."
            sleep "$RETRY_INTERVAL"
          done

          # Verify destination is accessible
          if [ ! -d "${dest}" ]; then
            log "ERROR: Destination ${dest} not accessible, aborting"
            notify "ops-sync failed on ${config.networking.hostName}" "Destination ${dest} not accessible"
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

        # Generous timeout for large syncs over Tailscale
        TimeoutStartSec = "8h";
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
