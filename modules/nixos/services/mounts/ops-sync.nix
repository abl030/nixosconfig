# Scheduled rclone mirror of Operations & Production from the Cullen file server to
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
# Source: WSL reads the SMB share itself with rclone's userspace SMB client
# (no mount). It used to read the Windows Z: mapping through drvfs, but WSL
# boots under an S4U scheduled-task logon that cannot use the saved Windows
# credential, so Z: was invisible after every reboot. A kernel CIFS mount was
# tried next and fails SMB signing against this server on the WSL 6.6 kernel,
# although the credential is valid. See
# docs/wiki/infrastructure/wsl-ondemand-data-mount.md.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.opsSync;
  # rclone on-the-fly remote: only this share subfolder is read.
  src = ":smb:${cfg.sourcePath}";
  # Dedicated ephemeral mountpoint for the narrow NFS mount below; the sync
  # writes here. wsl reaches tower over the Windows host's Tailscale subnet
  # route. The remote path has a space ("Ops Backup"); mounting it in-script
  # (vs an fstab entry) sidesteps fstab space-escaping entirely.
  opsMount = "/mnt/ops-backup";
  opsRemote = "192.168.1.2:/mnt/user/data/Life/Cullen/Ops Backup";
  dest = "${opsMount}/";
  credentials = config.sops.secrets."ops-sync/smb-credentials".path;
  sendNegativeAlert = import ../../lib/negative-alert.nix {inherit config lib pkgs;};
in {
  options.homelab.mounts.opsSync = {
    enable = mkEnableOption "Scheduled mirror of Operations & Production to home NFS";

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 21:00:00";
      description = "Systemd calendar expression for when to run the sync";
    };

    sourceHost = mkOption {
      type = types.str;
      default = "192.168.100.201";
      description = "SMB file server holding the sync source";
    };

    sourcePath = mkOption {
      type = types.str;
      default = "Data/Operations & Production";
      description = "Share plus subfolder read as the sync source";
    };
  };

  config = mkIf cfg.enable {
    # username=/password= lines (mount.cifs credentials format, kept from the
    # CIFS attempt). Root-only; host-scoped at secrets/hosts/<host>/ops-sync-cifs.cred.
    sops.secrets."ops-sync/smb-credentials" = {
      sopsFile = config.homelab.secrets.sopsFile "ops-sync-cifs.cred";
      format = "binary";
      owner = "root";
      mode = "0400";
    };

    systemd.services.ops-sync = {
      description = "Mirror Operations & Production to home NFS";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      restartIfChanged = false;
      # nfs-utils for mount.nfs (the just-in-time destination mount).
      path = [pkgs.rclone pkgs.coreutils pkgs.gnused pkgs.util-linux pkgs.nfs-utils pkgs.curl];

      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true; # rclone/mount as root; no setuid exec (#232)
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

          # rclone reads the SMB login from env; the password goes through
          # `rclone obscure -` on stdin so it never appears in argv.
          export RCLONE_CONFIG=/dev/null
          export RCLONE_SMB_HOST=${escapeShellArg cfg.sourceHost}
          RCLONE_SMB_USER="$(sed -n 's/^username=//p' "${credentials}")"
          RCLONE_SMB_PASS="$(sed -n 's/^password=//p' "${credentials}" | rclone obscure -)"
          export RCLONE_SMB_USER RCLONE_SMB_PASS

          source_available() {
            rclone lsf --max-depth 1 --contimeout 30s "${src}" >/dev/null
          }

          # Wait for source with retries (file server offline / site VPN down).
          attempt=0
          while ! source_available; do
            attempt=$((attempt + 1))
            if [ "$attempt" -gt "$MAX_RETRIES" ]; then
              log "Source ${cfg.sourceHost}/${cfg.sourcePath} not reachable after $MAX_RETRIES attempts — giving up"
              notify \
                "ops-sync skipped on ${config.networking.hostName}" \
                "Source ${cfg.sourceHost}/${cfg.sourcePath} not reachable after $MAX_RETRIES attempts. File server offline, route down, or credentials rejected (journalctl -u ops-sync) — will try again next scheduled run." \
                5
              exit 0
            fi
            log "Source ${cfg.sourceHost}/${cfg.sourcePath} not reachable (attempt $attempt/$MAX_RETRIES), retrying in ''${RETRY_INTERVAL}s..."
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

          log "Starting sync from ${cfg.sourceHost}/${cfg.sourcePath} to home NFS"

          # Mirror with deletes; excluded files on the destination are kept.
          rclone sync \
            --exclude 'Thumbs.db' \
            --exclude '.stfolder/**' \
            --exclude 'desktop.ini' \
            --exclude '~$*' \
            --timeout 5m \
            --contimeout 60s \
            --log-level INFO \
            --stats 15m \
            --stats-one-line \
            "${src}" "${dest}"

          log "Sync completed successfully"
        '';

        # Root: mount.nfs and the root-only credentials file
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
