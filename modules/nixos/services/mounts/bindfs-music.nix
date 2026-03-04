# Bindfs FUSE mount over NFS Music directory.
#
# NFS doesn't propagate inotify events. A bindfs FUSE mount mirrors
# the NFS path transparently — reads/writes pass through to NFS, but
# writes through the FUSE mount generate local inotify events. This
# lets the inotify-receiver create `refresh` markers that Lidarr's
# filesystem watcher actually sees.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.mounts.bindfsMusic;
in {
  options.homelab.mounts.bindfsMusic = {
    enable = lib.mkEnableOption "bindfs FUSE overlay for Music on NFS";

    source = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Music";
      description = "NFS-backed source directory to mirror.";
    };

    mountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/fuse/Media/Music";
      description = "Where to expose the bindfs FUSE mount.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pkgs.bindfs];

    systemd.tmpfiles.rules = [
      "d /mnt/fuse 0755 root root - -"
      "d /mnt/fuse/Media 0755 root root - -"
      "d /mnt/fuse/Media/Music 0755 root root - -"
    ];

    systemd.services.bindfs-music = {
      description = "bindfs FUSE mount for Music (inotify over NFS)";
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
      # Die when NFS goes away, restart when it comes back
      bindsTo = ["mnt-data.mount"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "forking";
        ExecStart = "${pkgs.bindfs}/bin/bindfs -o allow_other --no-allow-non-empty ${lib.escapeShellArg cfg.source} ${lib.escapeShellArg cfg.mountpoint}";
        ExecStop = "${pkgs.fuse}/bin/fusermount -u ${lib.escapeShellArg cfg.mountpoint}";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
