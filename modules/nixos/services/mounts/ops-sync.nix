# Scheduled rsync of Operations & Production from work Z: drive to home NFS
# Runs nightly, mirrors source with deletes, only copies changed files.
#
# forgejo#4: this runs UNATTENDED overnight on wsl — the fleet's least-trusted
# (Cullen-site) box. It used to depend on the shared /mnt/data automount (the
# WHOLE home NAS share, RW), so a compromise here could encrypt the entire NAS
# during the nightly window. Now it brings up its OWN narrow, RW NFS mount of
# JUST the Cullen backup subtree for the duration of the sync, then tears it
# down — so the unattended writer's blast radius is one folder, not the NAS.
# The interactive whole-share mount lives in hosts/wsl/data-mounts.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.opsSync;
  src = "/mnt/z/Operations & Production/";
  # Dedicated ephemeral mountpoint for the narrow NFS mount below; the sync
  # writes here. wsl reaches tower over the Windows host's Tailscale subnet
  # route. The remote path has a space ("Ops Backup"); mounting it in-script
  # (vs an fstab entry) sidesteps fstab space-escaping entirely.
  opsMount = "/mnt/ops-backup";
  opsRemote = "192.168.1.2:/mnt/user/data/Life/Cullen/Ops Backup";
  dest = "${opsMount}/";
  sendNegativeAlert = import ../../lib/negative-alert.nix {inherit config lib pkgs;};
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
      after = ["network-online.target" "mnt-z.automount"];
      wants = ["network-online.target"];
      restartIfChanged = false;
      # nfs-utils for mount.nfs (the narrow just-in-time mount below).
      path = [pkgs.rsync pkgs.coreutils pkgs.util-linux pkgs.nfs-utils pkgs.curl];

      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true; # rsync/zfs/ssh as root; no setuid exec (#232)
        ExecStart = pkgs.writeScript "ops-sync" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          MAX_RETRIES=5
          RETRY_INTERVAL=60

          log() { logger -t ops-sync "$1"; echo "$1"; }

          notify() {
            local title="$1" msg="$2" priority="''${3:-8}"
            ${sendNegativeAlert}
            send_negative_alert "$title" "$msg" "$priority"
          }

          trap 'notify "ops-sync failed on ${config.networking.hostName}" "Sync failed at line $LINENO"' ERR

          # Always tear down the narrow NFS mount, on success OR failure, so the
          # NAS is never left mounted after the sync (forgejo#4).
          cleanup() {
            if mountpoint -q "${opsMount}"; then
              umount -l "${opsMount}" 2>/dev/null || true
            fi
          }
          trap cleanup EXIT

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

          # Bring up a NARROW, RW NFS mount of just the Cullen backup subtree for
          # the duration of this sync (torn down by the EXIT trap). NEVER the
          # whole /mnt/data share — see module header (forgejo#4).
          mkdir -p "${opsMount}"
          if ! mountpoint -q "${opsMount}"; then
            log "Mounting ${opsRemote} -> ${opsMount} (read-write, sync only)"
            mount -t nfs -o nfsvers=4.2,soft,timeo=30,retrans=2,noatime \
              "${opsRemote}" "${opsMount}"
          fi

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
