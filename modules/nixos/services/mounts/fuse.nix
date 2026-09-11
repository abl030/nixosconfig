# FUSE union mounts for Jellyfin: Metadata (RW) + Media (RO) -> single view
# See docs/wiki/infrastructure/media-filesystem.md for the full layout
# (mergerfs + virtiofs + tower NFS, why two branches, Phase 1 of #208).
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.fuse;

  # dropcacheonclose=false: with cache.files=off, mergerfs would otherwise
  # posix_fadvise(DONTNEED) the underlying branch file on every close, so Jellyfin's
  # back-to-back passes over the same file (duration probe -> keyframe walk -> trickplay)
  # each re-read from the backend. `false` lets passes 2..N hit the guest page cache,
  # cutting I/O-pressure (PSI) during library scans / keyframe extraction. The 16G CT's
  # kernel evicts this cache under memory pressure, so the cost is bounded.
  # See docs/wiki/infrastructure/igpu-io-pressure-tuning.md.
  baseFlags =
    "allow_other,use_ino,cache.files=off,dropcacheonclose=false,"
    + "moveonenospc=true,minfreespace=20G,category.create=ff,"
    + "uid=1000,gid=100,umask=002";

  sh = "${pkgs.bash}/bin/bash";
  mfs = "${pkgs.mergerfs}/bin/mergerfs";
  umnt = "${pkgs.util-linux}/bin/umount";

  # Metadata (RW) lives on prom virtiofs (/mnt/virtio/media_metadata); media (RO)
  # for Movies/TV stays on tower NFS (/mnt/data), Music RO/RW is direct prom virtiofs.
  brMovies = "/mnt/virtio/media_metadata/Movies=RW:/mnt/data/Media/Movies=RO";
  brTV = "/mnt/virtio/media_metadata/TV Shows=RW:/mnt/data/Media/TV Shows=RO";
  brMusic = "/mnt/virtio/media_metadata/Music=RW:/mnt/virtio/Music=RO";
  brMusicRW = "/mnt/virtio/Music=RW";

  dstMovies = "/mnt/fuse/Media/Movies";
  dstTV = "/mnt/fuse/Media/TV_Shows";
  dstMusic = "/mnt/fuse/Media/Music";
  dstMusicRW = "/mnt/fuse/Media/Music_RW";

  mkExecStart = branchArgs: dest:
    "${sh} -lc " + lib.escapeShellArg "${mfs} -f -o ${baseFlags} '${branchArgs}' '${dest}'";
in {
  options.homelab.mounts.fuse = {
    enable = mkEnableOption "FUSE mergerfs unions for Jellyfin media";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [mergerfs]);
    programs.fuse.userAllowOther = true;

    systemd = {
      tmpfiles.rules = lib.mkOrder 1600 [
        "d /mnt/fuse 0755 root root -"
        "d /mnt/fuse/Media 0755 root root -"

        # These four are mergerfs MOUNT POINTS, so mode/owner are deliberately
        # "-" (create if absent, never touch what is already there).
        #
        # They used to be `0755 root root`, which is the bug that repeatedly
        # unmounted the Jellyfin music library. Once a union is mounted, a
        # tmpfiles chown/chmod of the mount point is passed straight THROUGH
        # mergerfs onto its RW branch. The mapping is exact:
        #
        #   /mnt/fuse/Media/Movies    -> /mnt/virtio/media_metadata/Movies
        #   /mnt/fuse/Media/TV_Shows  -> /mnt/virtio/media_metadata/TV Shows
        #   /mnt/fuse/Media/Music     -> /mnt/virtio/media_metadata/Music
        #   /mnt/fuse/Media/Music_RW  -> /mnt/virtio/Music
        #
        # ...which is precisely the set of directories that kept reverting to
        # root-owned 0755 and breaking `fuse-mergerfs-music`'s `test -w`
        # ExecStartPre. Confirmed 2026-09-11: an igpu activation at 09:27:49 left
        # all four owned by host 100000:100000, i.e. CONTAINER root, not host
        # root — so the writer was inside this container, not on prom or doc2.
        #
        # It looked intermittent only because a RUNNING union never re-checks:
        # the chown lands on every rebuild, but the failure surfaces solely when
        # a union restarts. Music restarted during the 2026-09-10 upgrade and so
        # was the only one to go down.
        #
        # Mount points need to exist, nothing more. Enforcing a mode on one is
        # meaningless while it is mounted and actively harmful because of the
        # passthrough. See docs/wiki/services/jellyfin-mergerfs-metadata-ownership.md
        "d /mnt/fuse/Media/Movies - - - -"
        "d /mnt/fuse/Media/TV_Shows - - - -"
        "d /mnt/fuse/Media/Music - - - -"
        "d /mnt/fuse/Media/Music_RW - - - -"

        # NOTE: the ownership guard for the RW metadata branches
        # (/mnt/virtio/media_metadata/{Movies,TV Shows,Music}) deliberately does
        # NOT live here. It cannot work from igpu.
        #
        # When those directories are reset to host root:root (observed twice on
        # 2026-09-10 and 2026-09-11, both at the instant doc2 activated), host
        # uid 0 is OUTSIDE this unprivileged CT's idmap. Chown is then refused
        # with EPERM no matter what capabilities the container holds, so igpu
        # can MAINTAIN correct ownership but can never RESTORE it — which is the
        # only case that matters. Verified empirically from inside CT 107.
        #
        # The guard therefore lives on doc2 (hosts/doc2/configuration.nix),
        # which mounts the same virtiofs WITHOUT idmapping and so holds real
        # root on these paths. See
        # docs/wiki/services/jellyfin-mergerfs-metadata-ownership.md
      ];

      # NNP-OK: these are mergerfs/FUSE mount units. Mounting a FUSE filesystem
      # can route through the setuid `fusermount` helper, which NoNewPrivileges
      # would block — so these units legitimately must NOT set it. (#232)
      services = {
        "fuse-mergerfs-movies" = {
          description = "mergerfs union for Movies (Metadata=RW, Media=RO)";
          after = ["mnt-data.mount"];
          requires = ["mnt-data.mount"];
          bindsTo = ["mnt-data.mount"];
          unitConfig.RequiresMountsFor = ["/mnt/virtio/media_metadata"];
          serviceConfig = {
            Type = "simple";
            ExecStart = mkExecStart brMovies dstMovies;
            ExecStop = "${umnt} ${dstMovies}";
            Restart = "on-failure";
          };
          wantedBy = ["multi-user.target"];
        };

        "fuse-mergerfs-tv" = {
          description = "mergerfs union for TV Shows (Metadata=RW, Media=RO)";
          after = ["mnt-data.mount"];
          requires = ["mnt-data.mount"];
          bindsTo = ["mnt-data.mount"];
          unitConfig.RequiresMountsFor = ["/mnt/virtio/media_metadata"];
          serviceConfig = {
            Type = "simple";
            ExecStart = mkExecStart brTV dstTV;
            ExecStop = "${umnt} ${dstTV}";
            Restart = "on-failure";
          };
          wantedBy = ["multi-user.target"];
        };

        # Music is pure virtiofs now (no tower NFS dependency).
        "fuse-mergerfs-music" = {
          description = "mergerfs union for Music (Metadata=RW, Media=RO)";
          unitConfig.RequiresMountsFor = ["/mnt/virtio/Music" "/mnt/virtio/media_metadata"];
          serviceConfig = {
            Type = "simple";

            # mergerfs performs normal file creates with the FUSE caller's
            # credentials, but its internal clone-path mkdirs run with the
            # daemon's primary group.  Music's RW metadata branch is gid 100
            # and setgid; without this, a new Beets directory that exists only
            # on the RO media branch cannot be mirrored for Jellyfin's NFO/LRC
            # writes even though Jellyfin itself has primary group `users`.
            Group = "users";
            ExecStartPre = "${pkgs.coreutils}/bin/test -w /mnt/virtio/media_metadata/Music";
            ExecStart = mkExecStart brMusic dstMusic;
            ExecStop = "${umnt} ${dstMusic}";
            Restart = "on-failure";
          };
          wantedBy = ["multi-user.target"];
        };

        "fuse-mergerfs-music-rw" = {
          description = "mergerfs wrapper for Music (direct RW service access)";
          unitConfig.RequiresMountsFor = ["/mnt/virtio/Music"];
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
  };
}
