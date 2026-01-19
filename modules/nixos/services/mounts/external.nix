# External NFS mount (mum's Synology via Tailscale)
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.external;
in {
  options.homelab.mounts.external = {
    enable = mkEnableOption "External NFS mount (mum's Synology via Tailscale)";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/mum" = {
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
  };
}
