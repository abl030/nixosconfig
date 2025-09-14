# FUSE passthrough mounts for Jellyfin to get inotify on top of NFS
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ bindfs ];

  # Ensure mountpoints exist
  systemd.tmpfiles.rules = [
    "d /mnt/fuse 0755 root root -"
    "d /mnt/fuse/Media 0755 root root -"
    "d /mnt/fuse/Media/Movies 0755 root root -"
    "d /mnt/fuse/Media/TV_Shows 0755 root root -"
    "d /mnt/fuse/Media/Music 0755 root root -"
  ];

  # Movies
  systemd.services."fuse-bindfs-movies" = {
    description = "FUSE bindfs passthrough for Movies";
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    serviceConfig = {
      # bindfs runs in the background by default; -f keeps it in the foreground for systemd
      Type = "simple";
      ExecStart = "${pkgs.bindfs}/bin/bindfs -f /mnt/data/Media/Movies /mnt/fuse/Media/Movies";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # TV Shows (note: systemd needs double-quotes for spaces)
  systemd.services."fuse-bindfs-tv" = {
    description = "FUSE bindfs passthrough for TV Shows";
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bindfs}/bin/bindfs -f \"/mnt/data/Media/TV Shows\" /mnt/fuse/Media/TV_Shows";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # Music
  systemd.services."fuse-bindfs-music" = {
    description = "FUSE bindfs passthrough for Music";
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bindfs}/bin/bindfs -f /mnt/data/Media/Music /mnt/fuse/Media/Music";
    };
    wantedBy = [ "multi-user.target" ];
  };
}

