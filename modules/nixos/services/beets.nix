# System-level Beets owner for the shared Cratedigger library.
{
  config,
  hostConfig,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.beets;
  operatorUser = hostConfig.user or "abl030";
  cratediggerPkgs = config.services.cratedigger.packageSet;
  applicationUser = config.services.cratedigger.user;

  library = "/mnt/virtio/cratedigger/beets-db/beets-library.db";
  directory = "/mnt/virtio/Music/Beets";
  stateFile = "/var/lib/beets/state.pickle";
  secretInclude = "/run/beets/secrets.yaml";
  rawToken = config.sops.secrets."beets/discogs-user-token".path;

  # The deployment, not Cratedigger, instantiates and owns this package.
  # Using Cratedigger's admitted package set keeps the checker, applications,
  # harness children, and plain operator CLI on one Python/Beets closure.
  beetsPackage = import (inputs.cratedigger-src + "/nix/beets.nix") {
    pkgs = cratediggerPkgs;
    discogsMirrorUrl = "http://192.168.1.44:8086";
    lrclibUrl = "http://192.168.1.43:3300/api";
  };
  beetsPython = cratediggerPkgs.python3.withPackages (_: [beetsPackage]);

  beetsYaml = (cratediggerPkgs.formats.yaml {}).generate "config.yaml" {
    inherit library directory;
    statefile = stateFile;
    include = [secretInclude];
    asciify_paths = true;
    clutter = [
      "Thumbs.DB"
      "Thumbs.db"
      ".DS_Store"
      "*.jpg"
      "*.png"
      "AlbumArt*"
      "Folder.*"
      "desktop.ini"
      "cratedigger.json"
    ];
    plugins = "musicbrainz discogs fetchart embedart lyrics lastgenre scrub info missing duplicates edit fromfilename ftintitle the inline permissions";
    import = {
      copy = false;
      autotag = true;
      write = true;
      move = true;
      timid = false;
      incremental = true;
      incremental_skip_later = true;
      log = "/mnt/virtio/cratedigger/beets-db/beets-import.log";
      languages = ["en"];
      duplicate_keys = {
        album = ["mb_albumid" "discogs_albumid"];
        item = ["artist" "title"];
      };
    };
    paths = {
      default = "$albumartist/$year - $album%aunique{albumartist album,path_disambig}/$track $title";
      singleton = "Non-Album/$artist/$title";
      comp = "Compilations/$album%aunique{albumartist album,path_disambig}/$track $title";
    };
    album_fields.path_disambig = "albumdisambig or releasegroupdisambig or catalognum or label or str(year)";
    musicbrainz = {
      host = "192.168.1.43:5200";
      https = false;
      ratelimit = 100;
    };
    match = {
      ignore_video_tracks = false;
      strong_rec_thresh = 0.10;
      medium_rec_thresh = 0.25;
      preferred = {
        countries = ["AU" "US" "GB|UK"];
        media = ["Digital Media|File" "CD"];
        original_year = true;
      };
    };
    permissions = {
      file = "0664";
      dir = "02775";
    };
    convert = {
      auto = false;
      auto_keep = false;
    };
    chroma.auto = false;
    fetchart = {
      auto = true;
      minwidth = 300;
      maxwidth = 500;
      quality = 75;
      high_resolution = false;
      sources = ["coverart" "itunes" "amazon" "albumart" "cover_art_url" "filesystem"];
    };
    embedart.auto = true;
    scrub.auto = true;
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
  configDir = cratediggerPkgs.runCommand "beets-external-config" {} ''
    mkdir -p "$out"
    ln -s ${beetsYaml} "$out/config.yaml"
  '';

  beet = cratediggerPkgs.writeShellScriptBin "beet" ''
    export BEETSDIR=${configDir}
    exec ${beetsPython}/bin/beet "$@"
  '';

  renderSecret = cratediggerPkgs.writeText "render-beets-secret.py" ''
    import grp
    import json
    import os
    import pathlib
    import sys
    import tempfile

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    token = source.read_text(encoding="utf-8")
    if not token:
        raise SystemExit("Beets Discogs token is empty")

    payload = "discogs:\n  user_token: " + json.dumps(token, ensure_ascii=False) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=".secrets.yaml.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chown(temporary, 0, grp.getgrnam("cratedigger-ops").gr_gid)
        os.chmod(temporary, 0o440)
        os.replace(temporary, destination)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
  '';

  initializeState = cratediggerPkgs.writeText "initialize-beets-state.py" ''
    import os
    import pathlib
    import pickle
    import sys
    import tempfile

    destination = pathlib.Path(sys.argv[1])
    if destination.exists():
        raise SystemExit(0)

    fd, temporary = tempfile.mkstemp(prefix=".state.pickle.", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            pickle.dump({}, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o660)
        os.replace(temporary, destination)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
  '';

  runtimeReady = cratediggerPkgs.writeShellScript "beets-runtime-ready" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/install -d -o root -g cratedigger-ops -m 0750 /var/lib/beets /run/beets
    test -r ${rawToken}
    ${beetsPython}/bin/python ${renderSecret} ${rawToken} ${secretInclude}
    ${beetsPython}/bin/python ${initializeState} ${stateFile}
    ${pkgs.coreutils}/bin/chown root:cratedigger-ops ${stateFile}
    ${pkgs.coreutils}/bin/chmod 0660 ${stateFile}
    test -r ${library}
    test -d ${directory}
  '';

  guardedApplications = lib.optionals config.services.cratedigger.enable [
    "cratedigger.service"
    "cratedigger-importer.service"
    "cratedigger-import-preview-worker.service"
    "cratedigger-web.service"
  ];
in {
  options.homelab.services.beets = {
    enable = lib.mkEnableOption "the system-owned Beets library authority";
    manageSharedStorage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this host owns the canonical shared catalog and library directory permissions.";
    };
    runtime = {
      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
      };
      configDir = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
      };
      expectedLibrary = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
      };
      expectedDirectory = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
      };
      expectedStateFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
      };
      expectedSecretInclude = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
      };
      readinessUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.services.beets.runtime = {
      package = beetsPackage;
      configDir = toString configDir;
      expectedLibrary = library;
      expectedDirectory = directory;
      expectedStateFile = stateFile;
      expectedSecretInclude = secretInclude;
      readinessUnits = ["beets-runtime-ready.service"];
    };

    assertions = [
      {
        assertion = beetsPackage.pythonModule == cratediggerPkgs.python3;
        message = "the system Beets package must use services.cratedigger.packageSet.python3";
      }
      {
        assertion = !cfg.manageSharedStorage || config.services.cratedigger.enable;
        message = "the host managing shared Beets storage must also run Cratedigger";
      }
      {
        assertion = !cfg.manageSharedStorage || applicationUser == "cratedigger";
        message = "shared Beets storage ownership is pinned to the live cratedigger UID";
      }
    ];

    users.groups.cratedigger-ops = {};
    users.users = lib.mkMerge [
      {
        ${operatorUser}.extraGroups = ["cratedigger-ops"];
      }
      (lib.mkIf config.services.cratedigger.enable {
        ${applicationUser}.extraGroups = ["cratedigger-ops"];
      })
      (lib.mkIf cfg.manageSharedStorage {
        ${applicationUser}.uid = 963;
      })
    ];

    sops.secrets."beets/discogs-user-token" = {
      sopsFile = config.homelab.secrets.sopsFile "beets-discogs.yaml";
      format = "yaml";
      key = "discogs_user_token";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = ["beets-runtime-ready.service"] ++ guardedApplications;
    };

    environment.systemPackages = [beet];

    systemd.tmpfiles.rules =
      ["d /var/lib/beets 0750 root cratedigger-ops -"]
      ++ lib.optionals cfg.manageSharedStorage [
        "d ${builtins.dirOf library} 2775 963 100 -"
        "d ${directory} 2775 963 100 -"
        "z ${library} 0664 963 100 -"
      ];

    systemd.services.beets-runtime-ready = {
      description = "Provision the deployment-owned Beets runtime authority";
      wantedBy = ["multi-user.target"];
      before = guardedApplications;
      restartTriggers = [configDir];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = runtimeReady;
        Group = "cratedigger-ops";
        RuntimeDirectory = "beets";
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/run/beets" "/var/lib/beets"];
        ReadOnlyPaths = [rawToken library directory];
        RestrictAddressFamilies = ["AF_UNIX"];
      };
    };
  };
}
