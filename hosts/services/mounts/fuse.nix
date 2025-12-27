# FUSE union mounts for Jellyfin: Metadata (RW) + Media (RO) -> single view
{
  pkgs,
  lib,
  ...
}: let
  # Common mergerfs flags:
  # - category.create=ff => always create in first branch (Metadata)
  # - per-branch =RW/=RO => hard safety
  # - cache.files=off,use_ino,dropcacheonclose => good for inotify/freshness
  # - moveonenospc,minfreespace => nicer low-space behavior
  baseFlags =
    "allow_other,use_ino,cache.files=off,dropcacheonclose=true,"
    + "moveonenospc=true,minfreespace=20G,category.create=ff";

  # Helpers to build safe shell commands (handles spaces via proper quoting)
  sh = "${pkgs.bash}/bin/bash";
  mfs = "${pkgs.mergerfs}/bin/mergerfs";
  umnt = "${pkgs.util-linux}/bin/umount";

  # Branch arguments (RW first, RO second)
  brMovies = "/mnt/data/Media/Metadata/Movies=RW:/mnt/data/Media/Movies=RO";
  brTV = "/mnt/data/Media/Metadata/TV Shows=RW:/mnt/data/Media/TV Shows=RO";
  brMusic = "/mnt/data/Media/Metadata/Music=RW:/mnt/data/Media/Music=RO";

  # --- NEW: Writable Music Branch for Lidarr/Music-Stack ---
  # Just wraps the remote share in mergerfs to generate local inotify events on write
  brMusicRW = "/mnt/data/Media/Music=RW";

  # Destinations
  dstMovies = "/mnt/fuse/Media/Movies";
  dstTV = "/mnt/fuse/Media/TV_Shows";
  dstMusic = "/mnt/fuse/Media/Music";
  dstMusicRW = "/mnt/fuse/Media/Music_RW"; # <--- New Mountpoint

  # Build a shell-wrapped ExecStart so quoted args with spaces work reliably
  mkExecStart = branchArgs: dest:
    "${sh} -lc " + lib.escapeShellArg "${mfs} -f -o ${baseFlags} '${branchArgs}' '${dest}'";
in {
  environment.systemPackages = with pkgs; [mergerfs];
  programs.fuse.userAllowOther = true;

  # Group all systemd configurations to avoid attribute set collisions and improve readability.
  # This makes it clear that this module configures multiple, related systemd units.
  systemd = {
    # Ensure target mountpoints exist
    tmpfiles.rules = [
      "d /mnt/fuse 0755 root root -"
      "d /mnt/fuse/Media 0755 root root -"
      "d /mnt/fuse/Media/Movies 0755 root root -"
      "d /mnt/fuse/Media/TV_Shows 0755 root root -"
      "d /mnt/fuse/Media/Music 0755 root root -"
      "d /mnt/fuse/Media/Music_RW 0755 root root -" # <--- New directory
    ];

    services = {
      # Movies
      "fuse-mergerfs-movies" = {
        description = "mergerfs union for Movies (Metadata=RW, Media=RO)";
        after = ["mnt-data.mount"];
        requires = ["mnt-data.mount"];
        bindsTo = ["mnt-data.mount"];
        serviceConfig = {
          Type = "simple";
          ExecStart = mkExecStart brMovies dstMovies;
          ExecStop = "${umnt} ${dstMovies}";
          Restart = "on-failure";
        };
        # We rely on mnt-data.mount; path checks are optional here since both branches live under /mnt/data
        wantedBy = ["multi-user.target"];
      };

      # TV Shows (note the space in the source path is handled via shell quoting)
      "fuse-mergerfs-tv" = {
        description = "mergerfs union for TV Shows (Metadata=RW, Media=RO)";
        after = ["mnt-data.mount"];
        requires = ["mnt-data.mount"];
        bindsTo = ["mnt-data.mount"];
        serviceConfig = {
          Type = "simple";
          ExecStart = mkExecStart brTV dstTV;
          ExecStop = "${umnt} ${dstTV}";
          Restart = "on-failure";
        };
        wantedBy = ["multi-user.target"];
      };

      # Music (Read-Only Media / Metadata RW)
      "fuse-mergerfs-music" = {
        description = "mergerfs union for Music (Metadata=RW, Media=RO)";
        after = ["mnt-data.mount"];
        requires = ["mnt-data.mount"];
        bindsTo = ["mnt-data.mount"];
        serviceConfig = {
          Type = "simple";
          ExecStart = mkExecStart brMusic dstMusic;
          ExecStop = "${umnt} ${dstMusic}";
          Restart = "on-failure";
        };
        wantedBy = ["multi-user.target"];
      };

      # --- NEW: Music RW (For Lidarr Stack) ---
      "fuse-mergerfs-music-rw" = {
        description = "mergerfs wrapper for Music (RW for Lidarr)";
        after = ["mnt-data.mount"];
        requires = ["mnt-data.mount"];
        bindsTo = ["mnt-data.mount"];
        serviceConfig = {
          Type = "simple";
          ExecStart = mkExecStart brMusicRW dstMusicRW;
          ExecStop = "${umnt} ${dstMusicRW}";
          Restart = "on-failure";
        };
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
