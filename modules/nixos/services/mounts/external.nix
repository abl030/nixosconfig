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

    # See docs/wiki/infrastructure/nfs-over-tailscale.md — `tailscale-wait`
    # is the real readiness gate; `nofail` keeps activation green if it
    # times out; the 30s mount-timeout fails fast instead of stalling 90s
    # on a broken tunnel.
    fileSystems."/mnt/mum" = {
      device = "100.100.237.21:/volumeUSB1/usbshare";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "nofail"
        "_netdev"
        "x-systemd.requires=tailscale-wait.service"
        "x-systemd.after=tailscale-wait.service"
        "x-systemd.mount-timeout=30s"
        "x-systemd.idle-timeout=300"
        "noatime"
        "retry=10"
      ];
    };
  };
}
