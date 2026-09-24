# Scheduled rsync of Operations & Production from the Cullen file server to
# home NFS. Runs nightly, mirrors source with deletes, only copies changed files.
#
# forgejo#4: this runs UNATTENDED overnight on wsl — the fleet's least-trusted
# (Cullen-site) box. It used to depend on the shared /mnt/data automount (the
# WHOLE home NAS share, RW), so a compromise here could encrypt the entire NAS
# during the nightly window. Now it brings up its OWN narrow, RW NFS mount of
# JUST the Cullen backup subtree for the duration of the sync, then tears it
# down — so the unattended writer's blast radius is one folder, not the NAS.
# The interactive whole-share mount lives in hosts/wsl/data-mounts.nix.
#
# Source: WSL mounts the SMB share itself (read-only CIFS, just the
# Operations & Production subfolder, sync-lifetime only). It used to read the
# Windows Z: mapping through drvfs, but that mapping holds no saved credential
# and drops after every Windows reboot, so the sync failed until someone
# reopened Z: by hand. See docs/wiki/infrastructure/wsl-ondemand-data-mount.md.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.opsSync;
  # Ephemeral read-only source mount; the subfolder is part of the UNC path so
  # nothing else on the file server is visible to the sync.
  srcMount = "/mnt/ops-source";
  src = "${srcMount}/";
  # Dedicated ephemeral mountpoint for the narrow NFS mount below; the sync
  # writes here. wsl reaches tower over the Windows host's Tailscale subnet
  # route. The remote path has a space ("Ops Backup"); mounting it in-script
  # (vs an fstab entry) sidesteps fstab space-escaping entirely.
  opsMount = "/mnt/ops-backup";
  opsRemote = "192.168.1.2:/mnt/user/data/Life/Cullen/Ops Backup";
  dest = "${opsMount}/";
  credentials = config.sops.secrets."ops-sync/cifs-credentials".path;
  sendNegativeAlert = import ../../lib/negative-alert.nix {inherit config lib pkgs;};
in {
  options.homelab.mounts.opsSync = {
    enable = mkEnableOption "Scheduled rsync of Operations & Production to home NFS";

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 21:00:00";
      description = "Systemd calendar expression for when to run the sync";
    };

    sourceShare = mkOption {
      type = types.str;
      default = "//192.168.100.201/Data/Operations & Production";
      description = "SMB path (share plus subfolder) mounted read-only as the sync source";
    };
  };

  config = mkIf cfg.enable {
    # mount.cifs `credentials=` file: username=/password= (optional domain=).
    # Root-only; host-scoped at secrets/hosts/<host>/ops-sync-cifs.cred.
    sops.secrets."ops-sync/cifs-credentials" = {
      sopsFile = config.homelab.secrets.sopsFile "ops-sync-cifs.cred";
      format = "binary";
      owner = "root";
      mode = "0400";
    };

    systemd.services.ops-sync = {
      description = "Rsync Operations & Production to home NFS";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      restartIfChanged = false;
      # cifs-utils/nfs-utils for mount.cifs/mount.nfs (the just-in-time mounts).
      path = [pkgs.rsync pkgs.coreutils pkgs.util-linux pkgs.cifs-utils pkgs.nfs-utils pkgs.curl];

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

          # Always tear down both sync-lifetime mounts, on success OR failure, so
          # neither share is left mounted after the sync (forgejo#4).
          cleanup() {
            for m in "${opsMount}" "${srcMount}"; do
              if mountpoint -q "$m"; then
                umount -l "$m" 2>/dev/null || true
              fi
            done
          }
          trap cleanup EXIT

          source_available() {
            mountpoint -q "${srcMount}" && return 0
            mount -t cifs -o ro,nosuid,nodev,noexec,credentials=${credentials},iocharset=utf8,noserverino \
              ${escapeShellArg cfg.sourceShare} "${srcMount}"
          }

          # Wait for source with retries (file server offline / site VPN down).
          mkdir -p "${srcMount}"
          attempt=0
          while ! source_available; do
            attempt=$((attempt + 1))
            if [ "$attempt" -gt "$MAX_RETRIES" ]; then
              log "Source ${cfg.sourceShare} not mountable after $MAX_RETRIES attempts — giving up"
              notify \
                "ops-sync skipped on ${config.networking.hostName}" \
                "Source ${cfg.sourceShare} not mountable after $MAX_RETRIES attempts. File server offline, route down, or credentials rejected (journalctl -u ops-sync) — will try again next scheduled run." \
                5
              exit 0
            fi
            log "Source ${cfg.sourceShare} not mountable (attempt $attempt/$MAX_RETRIES), retrying in ''${RETRY_INTERVAL}s..."
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

          log "Starting sync from ${cfg.sourceShare} to home NFS"

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

        # Root: mount.cifs/mount.nfs and the root-only credentials file
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
