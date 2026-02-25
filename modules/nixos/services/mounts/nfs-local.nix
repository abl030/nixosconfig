# Resilient static NFS mounts for local network
# Uses network-online.target instead of Tailscale
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfsLocal;
in {
  options.homelab.mounts.nfsLocal = {
    enable = mkEnableOption "NFS mounts via local network to Unraid";
    readOnly = mkEnableOption "mount /mnt/data read-only (safety for testing)";
  };

  config = mkIf cfg.enable {
    systemd.services.systemd-networkd-wait-online.enable = true;

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/data" = {
      device = "192.168.1.2:/mnt/user/data/";
      fsType = "nfs";
      options =
        [
          "x-systemd.requires=network-online.target"
          "x-systemd.after=network-online.target"
          "_netdev"
          "hard"
          "softreval"
          "timeo=50"
          "retrans=5"
          "noatime"
          "nfsvers=4.2"
        ]
        ++ lib.optional cfg.readOnly "ro";
    };

    fileSystems."/mnt/appdata" = {
      device = "192.168.1.2:/mnt/user/appdata/";
      fsType = "nfs";
      options = [
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        "_netdev"
        "hard"
        "softreval"
        "timeo=50"
        "retrans=5"
        "noatime"
        "nfsvers=4.2"
      ];
    };
  };
}
