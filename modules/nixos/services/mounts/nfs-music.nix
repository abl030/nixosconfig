# NFS client mount for Music library at /mnt/Music
# Exported directly from prom (Proxmox host) on ZFS — bypasses virtiofs
# which lacks FUSE_EXPORT_SUPPORT and causes stale NFS file handles.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfsMusic;
in {
  options.homelab.mounts.nfsMusic = {
    enable = mkEnableOption "NFS mount of Music library at /mnt/Music";

    server = mkOption {
      type = types.str;
      default = "192.168.1.12";
      description = "NFS server address for Music (default: prom LAN IP).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    # Server-side path is explicit (not `/`) because prom serves multiple
    # NFSv4 exports from different ZFS hierarchies and we cannot pin the
    # pseudo-root via `fsid=0` to any one of them — the kernel auto-generates
    # a synthesised root at `/` instead. See docs/wiki/infrastructure/pfsense-backup.md
    # for the 2026-05-26 cutover that motivated dropping fsid=0.
    fileSystems."/mnt/Music" = {
      device = "${cfg.server}:/nvmeprom/containers/Music";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "_netdev"
        "x-systemd.idle-timeout=300"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        "noatime"
        "nfsvers=4.2"
      ];
    };
  };
}
