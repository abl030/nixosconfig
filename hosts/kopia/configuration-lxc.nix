# kopia — dedicated unprivileged Proxmox LXC (CT 111) for the backup service.
#
# WHY THIS HOST EXISTS (forgejo#218)
# kopia used to run on doc2. On 2026-09-11 doc2 wedged during a kernel-update
# reboot because a stray kopia process could not be reaped: systemd-shutdown
# blocked forever on it, and it also held /mnt/virtio busy so the unmount failed.
# doc2 carries most services plus the whole LGTM stack AND Gotify, so kopia
# taking doc2 down also silenced the alert path that should have reported it.
#
# Splitting kopia out buys three things:
#   - blast radius: a wedged kopia wedges kopia, and `pct stop` on a container
#     is cheap and touches nothing else.
#   - reboot independence: doc2's kernel reboots no longer kill a verify that
#     legitimately runs 05:30-12:00 daily (2.7 TB over a ~45 Mbit/s offsite link).
#   - storage: no virtiofs in the path. Everything is a plain bind from prom.
#
# WHY AN LXC AND NOT A VM
# Measured on prom 2026-09-11: a plain bind mount does NOT carry ZFS child
# datasets (they appear empty), but a RECURSIVE bind does. That distinction is
# the whole reason the old prom-hosted pfSense backup "worked" while producing
# 298-byte snapshots — virtiofs and NFS both fail to cross submounts. Proxmox's
# own `mp:` entries use `mount -o bind` (PVE/LXC.pm:2060), so the pfsense tree
# gets a raw `lxc.mount.entry ... rbind` instead. See
# docs/wiki/infrastructure/pfsense-backup.md.
#
# MOUNTS (all provided by prom; an unprivileged CT cannot mount NFS itself)
#   /mnt/data                 <- prom /mnt/tower-data          (tower NFS)
#   /mnt/magazines            <- prom /mnt/tower-magazines     (tower NFS, RO)
#   /mnt/backup/vm-backups    <- prom /mnt/tower-vmbackups     (tower NFS, RO)
#   /mnt/mum                  <- prom /mnt/mum                 (Synology, tailscale)
#   /mnt/virtio/Music         <- prom nvmeprom/containers/Music
#   /mnt/virtio/ali-cratedigger <- prom nvmeprom/containers/ali-cratedigger
#   /mnt/backup/pfsense       <- prom nvmeprom/backup/pfsense  (RBIND — child datasets)
#   /mnt/virtio/kopia         <- prom nvmeprom/containers/kopia (dataDir + cache)
#
# The in-container paths are deliberately IDENTICAL to doc2's. kopia identifies a
# snapshot source by hostname+username+path, and both instances already pin
# overrideHostname="kopia"/overrideUsername="root", so keeping the paths the same
# means the existing snapshot history, policies and schedules keep matching
# rather than forking into a parallel set of sources.
{
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/virtualisation/proxmox-lxc.nix")];

  proxmoxLXC = {
    privileged = false;
    manageNetwork = true;
    manageHostName = true;
  };

  networking = {
    hostName = "kopia";
    useDHCP = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.46";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    # else conflicts with base.nix systemd-resolved
    useHostResolvConf = lib.mkForce false;
  };

  # Neutralise VM-isms inherited from base.nix (see the LXC guide).
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;

  # Deployed via push-deploy from doc1; a CT cannot arm the realtime timer.
  system.autoUpgrade.enable = lib.mkForce false;
  homelab.update = {
    enable = false;
    pushDeploy.enable = true;
  };

  homelab.services = {
    kopia = {
      enable = true;
      dataDir = "/mnt/virtio/kopia";
      instances = {
        photos = {
          port = 51515;
          configDir = "/mnt/virtio/kopia/photos";
          sources = [
            "/mnt/data/Life/Photos/library"
            # /mnt/data/Life joins the photos repo as a second source so it
            # dedupes against the photo blobs already here — the 314 GiB
            # library is never re-uploaded and incurs no fresh 90-day lock.
            # The regenerable/duplicate Photos subdirs and the high-churn
            # Unraid USB backup are dropped via sourceExcludes below;
            # Photos/backups (immich DB dumps) rides along into Wasabi.
            # See docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md.
            "/mnt/data/Life"
            # Wine-magazine archive (PDFs + EPUBs + JSON sidecars, ~2.6 GB)
            # on its dedicated single-disk share. Expensive to regenerate
            # (Marker ML conversion + sidecars; pre-2017 issues are 0-byte /
            # unrecoverable server-side), so it earns an offsite copy.
            "/mnt/magazines"
            # pfSense backup is intentionally NOT in kopia-photos: those
            # snapshots will live in a dedicated Wasabi bucket better
            # suited to small high-churn appliance backups. Existing
            # 298-byte snapshots in this repo will be `kopia snapshot
            # delete`d and age out under the 90-day Object Lock window.
            # See docs/wiki/infrastructure/pfsense-backup.md.
          ];
          # Anchored to the /mnt/data/Life source root. library is its own
          # source above; thumbs/encoded-video/upload are immich-regenerable;
          # UnraidUSB is a 4 GiB monthly full-rewrite that's re-creatable.
          # Photos/backups (immich DB) and Photos/profile are NOT excluded.
          sourceExcludes = {
            "/mnt/data/Life" = [
              "/Photos/library"
              "/Photos/thumbs"
              "/Photos/encoded-video"
              "/Photos/upload"
              "/Tech/Backups/UnraidUSB"
            ];
          };
          proxyHost = "kopiaphotos.ablz.au";
          # Match container identity so existing snapshot policies/schedules work
          overrideHostname = "kopia";
          overrideUsername = "root";
          runAsRoot = true;
        };
        mum = {
          port = 51516;
          configDir = "/mnt/virtio/kopia/mum";
          # Three deliberately-narrow subdirs — NOT all of /mnt/data
          # (which would include video media we don't ship offsite).
          # The 2026-02-26 migration silently dropped these from the
          # daemon schedule for 12 weeks (#254); the reconciler in
          # the new module + this declarative list (#255) keeps them
          # synced going forward.
          sources = [
            "/mnt/data/Life"
            "/mnt/data/Media/Books"
            "/mnt/data/Media/Music"
            # Prepared Yoto books plus Ali's low-volume music library. The
            # books used to ride under Media/Books/Yoto; keep the new
            # top-level Books/Music tree covered after the migration.
            "/mnt/data/Media/Yoto"
            # Wine-magazine archive on its dedicated single-disk share.
            # Synology offsite copy alongside the photos-repo (Wasabi) one.
            "/mnt/magazines"
            # Curated beets music library — its own ZFS dataset on prom
            # (nvmeprom/containers/Music), a virtiofs submount under /mnt/virtio.
            # Synology-only (re-downloadable; not worth per-GB Wasabi). Walks
            # ~100k files — relies on the #267 virtiofsd fd fix to avoid ENFILE.
            # See docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md.
            "/mnt/virtio/Music"
            # Ali's independent PostgreSQL, Beets DB, and Cratedigger state.
            "/mnt/virtio/ali-cratedigger"
            # pfSense ZFS backup, read-only NFS mount from prom. (Replaces
            # the earlier virtiofs share at /mnt/pfsense-backup — virtiofs
            # does not cross ZFS-submount boundaries reliably, so the
            # 12 child datasets that hold the actual 1.83 GB of data were
            # invisible to kopia and snapshots came in at 298 bytes.)
            # Full architecture: docs/wiki/infrastructure/pfsense-backup.md
            "/mnt/backup/pfsense"
            # VM backup archives from prom — age-encrypted weekly tarballs of
            # nvmeprom/containers written by containers-backup.service on doc1.
            # Tower exports VMBackups to doc2 read-only (HAOS gets the only rw
            # entry); we ship the encrypted .tar.gz.age files offsite to mum's
            # Synology. Requires: tower VMBackups NFS export scoped to
            # 192.168.1.35/36 ro — see the fileSystems entry below for the
            # full rule and why nothing else needs NFS on that share.
            "/mnt/backup/vm-backups/containers"
            # Home Assistant's nightly automatic backups (02:00, keep 7).
            # HAOS writes them itself over a Supervisor NFS backup mount
            # (192.168.1.20 is the only rw entry in tower's VMBackups export);
            # kopia-mum is what actually gets them off the LAN.
            # Full architecture: docs/wiki/services/home-assistant-auto-update.md
            "/mnt/backup/vm-backups/homeassistant"
          ];
          # Calibration encodes are regenerable scratch data. A 693 GiB run
          # monopolized Kopia's single scheduled upload queue for >13h on
          # 2026-07-27, preventing the other six daily sources from running.
          sourceExcludes = {
            "/mnt/virtio/Music" = ["/calibration-tmp"];
          };
          repositoryMounts = ["/mnt/mum"];
          proxyHost = "kopiamum.ablz.au";
          verifyPercent = 2;
          overrideHostname = "kopia";
          overrideUsername = "root";
          runAsRoot = true;
        };
      };
    };
  };

  system.stateVersion = "25.05";
}
