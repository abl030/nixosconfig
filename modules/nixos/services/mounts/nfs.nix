# NFS mounts to Unraid tower
# Mounts /mnt/data and /mnt/appdata with automount on access
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfs;
  useTailscale = cfg.server == "tower";
  serverRequires =
    if useTailscale
    then [
      "x-systemd.requires=tailscaled.service"
      "x-systemd.after=tailscaled.service"
    ]
    else [
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
    ];
in {
  options.homelab.mounts.nfs = {
    enable = mkEnableOption "NFS mounts to tower";

    server = mkOption {
      type = types.str;
      default = "tower";
      description = "NFS server address. Defaults to 'tower' (Tailscale MagicDNS). Set to a LAN IP to bypass Tailscale.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems."/mnt/data" = {
      device = "${cfg.server}:/mnt/user/data";
      fsType = "nfs";
      options =
        [
          "x-systemd.automount"
          "noauto"
          "_netdev"
          "x-systemd.idle-timeout=300"
          "noatime"
          "retry=10"
          "nfsvers=4.2"
        ]
        ++ serverRequires;
    };

    fileSystems."/mnt/appdata" = {
      device = "${cfg.server}:/mnt/user/appdata";
      fsType = "nfs";
      options =
        [
          "x-systemd.automount"
          "noauto"
          "_netdev"
          "x-systemd.idle-timeout=300"
          "noatime"
          "nfsvers=4.2"
        ]
        ++ serverRequires;
    };
  };
}
