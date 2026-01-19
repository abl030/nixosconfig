# NFS mounts via Tailscale to Unraid tower
# Mounts /mnt/data and /mnt/appdata with automount on access
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfs;
in {
  options.homelab.mounts.nfs = {
    enable = mkEnableOption "NFS mounts via Tailscale to tower";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/data" = {
      device = "tower:/mnt/user/data";
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
        "nfsvers=4.2"
      ];
    };

    fileSystems."/mnt/appdata" = {
      device = "tower:/mnt/user/appdata";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "_netdev"
        "x-systemd.requires=tailscaled.service"
        "x-systemd.idle-timeout=300"
        "noatime"
        "nfsvers=4.2"
      ];
    };
  };
}
