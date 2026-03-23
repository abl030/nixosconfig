# NFS client mount for doc2's music library at /mnt/Music
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfsMusic;
  hasTailscale = config.services.tailscale.enable or false;
  useTailscale = cfg.server != "192.168.1.35" && hasTailscale;
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
  options.homelab.mounts.nfsMusic = {
    enable = mkEnableOption "NFS mount of doc2 music library at /mnt/Music";

    server = mkOption {
      type = types.str;
      default = "192.168.1.35";
      description = "doc2 NFS server address. Use Tailscale IP for off-LAN access.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    fileSystems."/mnt/Music" = {
      device = "${cfg.server}:/mnt/virtio/Music";
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
