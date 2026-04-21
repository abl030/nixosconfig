# =============================================================================
# Beets Music Tagger — Home Manager Module Wrapper
# =============================================================================
#
# This module wraps Home Manager's built-in `programs.beets` to provide a
# `homelab.beets.enable` toggle consistent with the rest of this repo.
#
# FILE LAYOUT:
#   Module:    /home/abl030/nixosconfig/modules/home-manager/services/beets.nix  (this file)
#   Index:     /home/abl030/nixosconfig/modules/home-manager/default.nix         (imports this)
#   Host HM:   /home/abl030/nixosconfig/hosts/proxmox-vm/home.nix               (enable here for doc1)
#   Generated: ~/.config/beets/config.yaml                                       (output of settings)
#
# ENABLING:
#   In the host's home.nix:
#     homelab.beets.enable = true;
#
# REBUILDING doc1 (hostname is "proxmox-vm"):
#   From the repo on doc1 itself:
#     cd /home/abl030/nixosconfig
#     sudo nixos-rebuild switch --flake .#proxmox-vm
#   From a remote machine:
#     nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm
#   Formatting (must pass before committing):
#     nix fmt
#
# =============================================================================
# HOME MANAGER `programs.beets` OPTIONS REFERENCE
# =============================================================================
#
# programs.beets.enable : bool (default: false)
#   Installs beets and generates ~/.config/beets/config.yaml from `settings`.
#
# programs.beets.package : package (default: pkgs.beets)
#   The beets package. Override to add extra plugin packages, e.g.:
#     package = pkgs.beets.override { pluginOverrides = { chroma.enable = true; }; };
#   Or use pkgs.python3Packages.beets-alternatives etc. for third-party plugins.
#
# programs.beets.settings : attrs (default: {})
#   Free-form attribute set serialised to YAML → ~/.config/beets/config.yaml.
#   Any valid beets config key works here. Example:
#
#     settings = {
#       directory = "/mnt/data/Media/Music";
#       library = "/home/abl030/.local/share/beets/library.db";
#       import = {
#         move = true;
#         write = true;
#         timid = false;
#       };
#       plugins = "fetchart embedart lastgenre scrub chroma replaygain";
#       fetchart.auto = true;
#       embedart.auto = true;
#       lastgenre.auto = true;
#       replaygain.backend = "ffmpeg";
#       match.preferred = {
#         countries = ["AU" "US" "GB"];
#         original_year = true;
#       };
#     };
#
# programs.beets.mpdIntegration.enableStats : bool (default: false)
#   Enables the mpdstats plugin AND a systemd user service that connects to MPD
#   and records play statistics back into the beets database.
#
# programs.beets.mpdIntegration.enableUpdate : bool (default: false)
#   Enables the mpdupdate plugin which tells MPD to update its database whenever
#   beets imports or modifies music files.
#
# programs.beets.mpdIntegration.host : string (default: "localhost")
#   MPD host for the mpdstats service to connect to.
#
# programs.beets.mpdIntegration.port : int (default: 6600)
#   MPD port for the mpdstats service to connect to.
#
# =============================================================================
# AVAILABLE BEETS PLUGINS (nixpkgs, beets 2.5.1)
# =============================================================================
#
# All of these are included in the default `pkgs.beets` package. To use them,
# just add their name to the `plugins` string in `settings`. No extra package
# overrides needed for built-in plugins.
#
# METADATA & TAGGING:
#   chroma          - Chromaprint acoustic fingerprinting (needs `pkgs.chromaprint`)
#   discogs         - Discogs metadata source
#   deezer          - Deezer metadata source
#   spotify         - Spotify metadata source
#   musicbrainz     - MusicBrainz (enabled by default, core source)
#   mbsync          - Sync metadata updates from MusicBrainz
#   mbsubmit        - Submit fingerprints to MusicBrainz
#   mbcollection    - Maintain MusicBrainz collection
#   fromfilename    - Guess metadata from filenames
#   ftintitle       - Move featured artists to title field
#   parentwork      - Fetch parent work from MusicBrainz
#   absubmit        - Submit acoustic analysis to AcousticBrainz
#   lastgenre       - Fetch genres from Last.fm
#   lastimport      - Import play counts from Last.fm
#   listenbrainz    - Submit listens to ListenBrainz
#   fetchart        - Fetch album art from various sources
#   embedart        - Embed album art into audio files
#   lyrics          - Fetch lyrics
#   replaygain      - Calculate ReplayGain values (backends: ffmpeg, gstreamer)
#   scrub           - Remove extraneous metadata/tags
#   zero            - Nullify specific tag fields
#
# LIBRARY MANAGEMENT:
#   duplicates      - Find duplicate tracks/albums
#   missing         - List missing tracks in albums
#   unimported      - Find files in library dir not in database
#   badfiles        - Check for corrupt files (needs `pkgs.flac`, `pkgs.mp3val`)
#   bucket          - Group albums into bucket directories
#   convert         - Transcode to other formats on import/demand
#   permissions     - Set file permissions after import
#   edit            - Edit metadata in $EDITOR
#   info            - Show file metadata/tags
#   export          - Export library data as JSON/CSV
#   types           - Define custom flexible attribute types
#   inline          - Compute template fields from Python expressions
#   replace         - Custom path character replacements
#   rewrite         - Path rewrite rules
#   advancedrewrite - More powerful path rewriting
#   substitute      - Regex substitution on metadata fields
#   the             - Move "The" in artist names for sorting
#   albumtypes      - Add album type to path templates
#   hook            - Run shell commands on beets events
#   importadded     - Set "added" date from file mtime on import
#   importfeeds     - Log imported files (m3u, symlinks, etc.)
#
# PLAYBACK & INTEGRATION:
#   play            - Play tracks with external player
#   playlist        - Use M3U playlists with beets
#   smartplaylist   - Generate smart playlists from queries
#   random          - Pick random tracks/albums
#   web             - Web UI and API for browsing library
#   bpd             - Beets as MPD server
#   mpdstats        - Record MPD play stats (see mpdIntegration above)
#   mpdupdate       - Tell MPD to update after import
#   embyupdate      - Notify Emby server of changes
#   kodiupdate      - Notify Kodi of changes
#   plexupdate      - Notify Plex of changes
#   sonosupdate     - Notify Sonos of changes
#   subsonicupdate  - Notify Subsonic of changes
#   subsonicplaylist - Sync playlists to Subsonic
#   aura            - AURA API server
#
# THIRD-PARTY PLUGIN PACKAGES (need package override):
#   pkgs.python3Packages.beets-alternatives  - Manage alternative library formats
#   pkgs.python3Packages.beets-audible       - Audible audiobook support
#   pkgs.python3Packages.beets-copyartifacts - Copy non-music files during import
#   pkgs.python3Packages.beets-filetote      - Move extra files with imports
#
# To add third-party plugins, override the package:
#   programs.beets.package = pkgs.beets.override {
#     pluginOverrides = {
#       alternatives.enable = true;
#     };
#   };
#   ...or wrap with extra Python packages as needed.
#
# =============================================================================
# BEETS REFERENCE DOCUMENTATION (offline, in nix store)
# =============================================================================
#
# The full beets docs (RST format, plain text) are available locally in the nix
# store. They are the upstream source files — readable directly, no browser or
# pandoc needed.
#
# STEP 1: Materialise the docs (one-time, ~1.5 MB download)
#
#   Run this command to fetch the beets source into the nix store and get
#   the store path:
#
#     nix build nixpkgs#beets.src --no-link --print-out-paths
#
#   This prints a path like:
#     /nix/store/<hash>-source
#
#   Save this as BEETS_SRC for the commands below. The docs live at:
#     ${BEETS_SRC}/docs/
#
# STEP 2: Browse the docs
#
#   DOC TREE (key files):
#
#   ${BEETS_SRC}/docs/
#   ├── reference/
#   │   ├── config.rst       (1181 lines) — ALL config.yaml options
#   │   ├── cli.rst          (538 lines)  — CLI commands reference
#   │   ├── pathformat.rst   (292 lines)  — Path format templates
#   │   └── query.rst        (443 lines)  — Query syntax
#   ├── plugins/
#   │   ├── index.rst        (706 lines)  — Plugin overview & list
#   │   ├── fetchart.rst     — one file per plugin, named by plugin
#   │   ├── chroma.rst
#   │   └── ...              (80+ plugin doc files)
#   ├── guides/
#   │   ├── main.rst         — Getting started guide
#   │   ├── tagger.rst       — Autotagger guide
#   │   └── advanced.rst     — Advanced usage
#   └── faq.rst              — Frequently asked questions
#
# STEP 3: Read docs with the Read tool
#
#   Use the Read tool with offset/limit for pagination:
#
#     Read file_path="${BEETS_SRC}/docs/reference/config.rst"
#     Read file_path="${BEETS_SRC}/docs/reference/config.rst" offset=100 limit=80
#     Read file_path="${BEETS_SRC}/docs/plugins/fetchart.rst"
#
# STEP 4: Search docs with the Grep tool
#
#   Search across all docs:
#     Grep pattern="import" path="${BEETS_SRC}/docs/reference" output_mode="content"
#
#   Search plugin docs:
#     Grep pattern="auto" path="${BEETS_SRC}/docs/plugins" output_mode="content" head_limit=20
#
#   Find which file covers a topic:
#     Grep pattern="replaygain" path="${BEETS_SRC}/docs" output_mode="files_with_matches"
#
# QUICK REFERENCE — most useful doc files for configuration work:
#
#   config.yaml options → ${BEETS_SRC}/docs/reference/config.rst
#   Path templates      → ${BEETS_SRC}/docs/reference/pathformat.rst
#   Query syntax        → ${BEETS_SRC}/docs/reference/query.rst
#   Plugin config       → ${BEETS_SRC}/docs/plugins/<plugin-name>.rst
#
# =============================================================================
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.beets;
  # Patch beets plugins to use local mirrors instead of upstream APIs:
  # - lyrics.py → local LRCLIB at 192.168.1.35:3300
  # - discogs.py → local Discogs mirror at discogs.ablz.au (issue #69)
  beetsWithLocalMirrors = pkgs.beets.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        substituteInPlace beetsplug/lyrics.py \
          --replace-fail 'BASE_URL = "https://lrclib.net/api"' \
                         'BASE_URL = "http://192.168.1.35:3300/api"'

        substituteInPlace beetsplug/discogs/__init__.py \
          --replace-fail 'self.discogs_client = Client(USER_AGENT, user_token=user_token)' \
                         'self.discogs_client = Client(USER_AGENT, user_token=user_token); self.discogs_client._base_url = "https://discogs.ablz.au"' \
          --replace-fail 'self.discogs_client = Client(USER_AGENT, c_key, c_secret, token, secret)' \
                         'self.discogs_client = Client(USER_AGENT, c_key, c_secret, token, secret); self.discogs_client._base_url = "https://discogs.ablz.au"'
      '';
  });
in {
  options.homelab.beets = {
    enable = lib.mkEnableOption "Beets music tagger and library manager";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.chromaprint
      pkgs.sqlite
      pkgs.lame
      pkgs.flac
      pkgs.mp3val
      pkgs.python3Packages.mutagen
    ];

    programs.beets = {
      enable = true;
      package = beetsWithLocalMirrors;
      settings = {
        directory = "/mnt/virtio/Music/Beets";
        library = "/mnt/virtio/Music/beets-library.db";

        # Files left behind after move that should be treated as empty dir
        clutter = ["Thumbs.DB" "Thumbs.db" ".DS_Store" "*.jpg" "*.png" "AlbumArt*" "Folder.*" "desktop.ini"];

        import = {
          copy = false;
          write = true;
          move = true;
          timid = false;
          incremental = true;
          incremental_skip_later = true;
          log = "/mnt/virtio/Music/beets-import.log";

          # MUST be under `import:` — beets reads it strictly from
          # config["import"]["duplicate_keys"]["album"]. A top-level
          # `duplicate_keys =` is silently ignored and beets falls back
          # to the default `[albumartist, album]` (no mb_albumid). That
          # silent fallback enabled the 2026-04-20 Shearwater "Palo Santo"
          # data-loss event: find_duplicates matched a cross-MBID sibling
          # on (albumartist, album) alone, the harness sent "remove"
          # thinking it was a same-MBID stale entry, and beets'
          # task.should_remove_duplicates blast-radius wiped the sibling.
          duplicate_keys = {
            album = ["albumartist" "album" "mb_albumid"];
            item = ["artist" "title"];
          };
        };

        paths = {
          default = "$albumartist/$year - $album%aunique{albumartist album,albumtype year label catalognum albumdisambig releasegroupdisambig short_mbid}/$track $title";
          singleton = "Non-Album/$artist/$title";
          comp = "Compilations/$album%aunique{albumartist album,albumtype year label catalognum albumdisambig releasegroupdisambig short_mbid}/$track $title";
        };

        item_fields = {
          short_mbid = "mb_albumid[:8] if mb_albumid else ''";
        };

        album_fields = {
          short_mbid = "mb_albumid[:8] if mb_albumid else ''";
        };

        musicbrainz = {
          host = "192.168.1.35:5200";
          https = false;
          ratelimit = 100;
        };

        match = {
          strong_rec_thresh = 0.10;
          medium_rec_thresh = 0.25;
          preferred = {
            countries = ["AU" "US" "GB|UK"];
            media = ["Digital Media|File" "CD"];
            original_year = true;
          };
        };

        # chroma disabled (hangs on long tracks). discogs enabled for stubborn albums.
        plugins = "musicbrainz discogs fetchart embedart lyrics lastgenre scrub info missing duplicates edit fromfilename ftintitle the inline";

        # Secrets (tokens, API keys) live in a local include file
        # outside of the nix store. See ~/.config/beets/secrets.yaml
        include = ["secrets.yaml"];

        chroma = {
          auto = false;
        };

        fetchart = {
          auto = true;
          minwidth = 300;
          maxwidth = 500;
          quality = 75;
          high_resolution = false;
          sources = [
            "coverart" # MusicBrainz Cover Art Archive — highest quality, always try first
            "itunes" # Apple Music — high-res, good coverage
            "amazon" # Amazon — decent fallback
            "albumart" # albumart.org
            "cover_art_url" # URL from MB release
            "filesystem" # Local cover.jpg — LAST resort, catches legacy tiny art
          ];
        };

        embedart = {
          auto = true;
        };

        scrub = {
          auto = true;
        };

        lyrics = {
          auto = true;
          synced = true;
          sources = ["lrclib"];
        };

        lastgenre = {
          auto = true;
          count = 3;
          source = "album";
          canonical = true;
          separator = ", ";
          force = false;
        };

        the = {
          a = true;
          the = true;
        };
      };
    };
  };
}
