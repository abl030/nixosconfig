# Ali's low-volume, Yoto-oriented Cratedigger deployment.
#
# The application runs in a NixOS container so the upstream singleton module
# gets its own systemd, nginx, Redis, PostgreSQL, Beets, and mutable namespaces.
# Only the positively-owned slskd download tree and metadata mirrors are shared
# with the archival instance. See docs/wiki/services/ali-cratedigger.md.
{
  config,
  hostConfig,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.aliCratedigger;
  operatorUser = hostConfig.user or "abl030";

  dataRoot = "/mnt/virtio/ali-cratedigger";
  library = "/mnt/data/Media/Yoto/Music";
  beetsLibrary = "${dataRoot}/beets-db/beets-library.db";
  beetsStateFile = "/var/lib/beets-ali/state.pickle";
  beetsSecretDir = "/run/beets";
  beetsSecretInclude = "${beetsSecretDir}/secrets.yaml";
  slskdDownloadDir = "/mnt/virtio/music/slskd";
  slskdSecretSource = "/run/cratedigger-secrets/SOULARR_SLSKD_API_KEY";

  gatewayPort = 18088;
  aliUid = 960;
  aliGid = 960;

  cratediggerPkgs = pkgs;
  beetsPackage = import (inputs.cratedigger-src + "/nix/beets.nix") {
    pkgs = cratediggerPkgs;
    discogsMirrorUrl = "http://192.168.1.44:8086";
    lrclibUrl = "http://192.168.1.43:3300/api";
  };
  beetsPython = cratediggerPkgs.python3.withPackages (_: [beetsPackage]);
  beetsYaml = (cratediggerPkgs.formats.yaml {}).generate "ali-beets-config.yaml" {
    library = beetsLibrary;
    directory = library;
    statefile = beetsStateFile;
    include = [beetsSecretInclude];
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
    plugins = "musicbrainz mbsync discogs fetchart embedart lyrics lastgenre scrub info missing duplicates edit fromfilename ftintitle the inline permissions";
    import = {
      copy = false;
      autotag = true;
      write = true;
      move = true;
      timid = false;
      incremental = true;
      incremental_skip_later = true;
      log = "${dataRoot}/beets-db/beets-import.log";
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
      sources = ["coverart" "cover_art_url" "itunes" "amazon" "albumart" "filesystem"];
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
  beetsConfigDir = cratediggerPkgs.runCommand "ali-beets-config" {} ''
    mkdir -p "$out"
    ln -s ${beetsYaml} "$out/config.yaml"
  '';
  initializeBeetsState = cratediggerPkgs.writeText "initialize-ali-beets-state.py" ''
    import os
    import pathlib
    import pickle
    import tempfile

    destination = pathlib.Path(${builtins.toJSON beetsStateFile})
    if not destination.exists():
        fd, temporary = tempfile.mkstemp(prefix=".state.pickle.", dir=destination.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                pickle.dump({}, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o660)
            os.replace(temporary, destination)
        except BaseException:
            pathlib.Path(temporary).unlink(missing_ok=True)
            raise
  '';

  aliYotoZip = pkgs.writers.writePython3Bin "ali-yoto-zip" {
    libraries = [];
    flakeIgnore = ["E501" "W503" "W504"];
  } (builtins.readFile ./ali-cratedigger/zip-albums.py);
in {
  options.homelab.services.aliCratedigger.enable =
    lib.mkEnableOption "Ali's isolated Yoto-oriented Cratedigger instance";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.services.cratedigger.enable;
        message = "Ali Cratedigger shares the existing slskd authority and requires the primary Cratedigger deployment.";
      }
      {
        assertion = config.homelab.services.yotoShare.enable;
        message = "Ali Cratedigger publishes its library through the Yoto share.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${dataRoot} 0755 root root -"
      "d ${dataRoot}/beets-db 2775 ${toString aliUid} ${toString aliGid} -"
      "d ${dataRoot}/processing 0700 ${toString aliUid} ${toString aliGid} -"
      "d ${dataRoot}/staging 2775 ${toString aliUid} ${toString aliGid} -"
      "d ${dataRoot}/state 0700 ${toString aliUid} ${toString aliGid} -"
      "d /var/lib/ali-cratedigger 0755 root root -"
      "d /var/lib/ali-cratedigger/postgresql 0750 ${toString config.ids.uids.postgres} ${toString config.ids.gids.postgres} -"
      "d /mnt/data/Media/Yoto 2755 ${toString aliUid} ${toString aliGid} -"
      "d /mnt/data/Media/Yoto/Books 2755 ${toString aliUid} ${toString aliGid} -"
      "d ${library} 2775 ${toString aliUid} ${toString aliGid} -"
    ];

    containers.ali-cratedigger = {
      autoStart = true;
      privateNetwork = false;
      bindMounts = {
        ${dataRoot} = {
          hostPath = dataRoot;
          isReadOnly = false;
        };
        ${library} = {
          hostPath = library;
          isReadOnly = false;
        };
        ${slskdDownloadDir} = {
          hostPath = slskdDownloadDir;
          isReadOnly = false;
        };
        "/var/lib/postgresql" = {
          hostPath = "/var/lib/ali-cratedigger/postgresql";
          isReadOnly = false;
        };
        ${slskdSecretSource} = {
          hostPath = slskdSecretSource;
          isReadOnly = true;
        };
        ${beetsSecretDir} = {
          hostPath = beetsSecretDir;
          isReadOnly = true;
        };
      };
      config = {
        lib,
        pkgs,
        ...
      }: {
        imports = [inputs.cratedigger-src.nixosModules.default];

        networking = {
          hostName = "ali-cratedigger";
          enableIPv6 = false;
          firewall.enable = false;
        };

        users.groups = {
          ali-music.gid = aliGid;
          cratedigger-ops.gid = 969;
          music-import.gid = 968;
        };
        users.users.cratedigger = {
          uid = aliUid;
          group = "ali-music";
          extraGroups = ["cratedigger-ops" "music-import"];
        };

        systemd.tmpfiles.rules = [
          "d ${dataRoot}/beets-db 2775 cratedigger ali-music -"
          "d ${dataRoot}/processing 0700 cratedigger ali-music -"
          "d ${dataRoot}/staging 2775 cratedigger ali-music -"
          "d ${dataRoot}/state 0700 cratedigger ali-music -"
          "d ${library} 2775 cratedigger ali-music -"
          "d /var/lib/beets-ali 0750 root cratedigger-ops -"
          "d /run/beets-ali 0750 root cratedigger-ops -"
        ];

        systemd.services = {
          ali-beets-runtime-ready = {
            description = "Provision Ali's deployment-owned Beets runtime";
            wantedBy = ["multi-user.target"];
            before = [
              "ali-beets-catalog-ready.service"
              "cratedigger.service"
              "cratedigger-importer.service"
              "cratedigger-import-preview-worker.service"
              "cratedigger-web.service"
            ];
            restartTriggers = [beetsConfigDir];
            stopIfChanged = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Group = "cratedigger-ops";
              UMask = "0077";
              ExecStart = pkgs.writeShellScript "ali-beets-runtime-ready" ''
                set -euo pipefail
                install -d -m 0750 -o root -g cratedigger-ops /var/lib/beets-ali /run/beets-ali
                ${beetsPython}/bin/python ${initializeBeetsState}
                chown root:cratedigger-ops ${beetsStateFile}
                chmod 0660 ${beetsStateFile}
                test -s ${beetsSecretInclude}
                test -d ${library}
              '';
              NoNewPrivileges = true;
              PrivateTmp = true;
              PrivateNetwork = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = ["/run/beets-ali" "/var/lib/beets-ali"];
              ReadOnlyPaths = [beetsSecretInclude library];
              RestrictAddressFamilies = ["AF_UNIX"];
            };
          };

          ali-beets-catalog-ready = {
            description = "Initialize Ali's independent Beets catalog";
            wantedBy = ["multi-user.target"];
            after = ["ali-beets-runtime-ready.service"];
            requires = ["ali-beets-runtime-ready.service"];
            before = [
              "cratedigger.service"
              "cratedigger-importer.service"
              "cratedigger-import-preview-worker.service"
              "cratedigger-web.service"
            ];
            restartTriggers = [beetsConfigDir];
            stopIfChanged = false;
            environment.BEETSDIR = toString beetsConfigDir;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "cratedigger";
              Group = "ali-music";
              SupplementaryGroups = ["cratedigger-ops"];
              ExecStart = "${beetsPython}/bin/beet ls";
              NoNewPrivileges = true;
              PrivateTmp = true;
              PrivateNetwork = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = ["/var/lib/beets-ali" "${dataRoot}/beets-db"];
              ReadOnlyPaths = [beetsSecretInclude library];
              RestrictAddressFamilies = ["AF_UNIX"];
            };
          };

          ali-yoto-zip = {
            description = "Publish Ali's Beets albums as Yoto-compatible ZIP files";
            after = ["ali-beets-runtime-ready.service"];
            requires = ["ali-beets-runtime-ready.service"];
            unitConfig.RequiresMountsFor = [library];
            serviceConfig = {
              Type = "oneshot";
              User = "cratedigger";
              Group = "ali-music";
              ExecStart = "${aliYotoZip}/bin/ali-yoto-zip ${lib.escapeShellArg library}";
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              PrivateDevices = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [library];
              RestrictAddressFamilies = ["AF_UNIX"];
              RestrictNamespaces = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              SystemCallArchitectures = "native";
              SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
            };
          };
        };

        systemd.timers.ali-yoto-zip = {
          description = "Refresh Ali's Yoto album ZIP files";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitInactiveSec = "5min";
            Persistent = true;
          };
        };

        environment.systemPackages = [
          (pkgs.writeShellScriptBin "ali-beet" ''
            export BEETSDIR=${beetsConfigDir}
            exec ${beetsPython}/bin/beet "$@"
          '')
        ];

        services.cratedigger = {
          enable = true;
          src = inputs.cratedigger-src;
          user = "cratedigger";
          group = "ali-music";
          stateDir = "${dataRoot}/state";
          processingDir = "${dataRoot}/processing";
          timer = {
            onBootSec = "10min";
            onUnitInactiveSec = "5min";
          };
          importer.previewWorkers = 1;
          slskd = {
            apiKeyFile = "/run/cratedigger-secrets/SOULARR_SLSKD_API_KEY";
            hostUrl = "http://192.168.21.2:5030";
            downloadDir = slskdDownloadDir;
          };
          pipelineDb.createLocally = true;
          redis = {
            port = 6380;
            maxmemory = "256mb";
          };
          searchSettings = {
            parallelSearches = 1;
            numberOfAlbumsToGrab = 2;
            allowedFiletypes = [
              "flac 24/192"
              "flac 24/96"
              "flac 24/48"
              "flac 16/44.1"
              "flac"
              "alac"
              "wav"
              "mp3 v0"
              "mp3 320"
              "aac"
              "mp3"
            ];
          };
          musicbrainz.apiBase = "http://192.168.1.43:5200";
          discogs.apiBase = "http://192.168.1.44:8086";
          beets = {
            runtime = {
              package = beetsPackage;
              configDir = toString beetsConfigDir;
              expectedLibrary = beetsLibrary;
              expectedDirectory = library;
              expectedStateFile = beetsStateFile;
              expectedSecretInclude = beetsSecretInclude;
              readinessUnits = [
                "ali-beets-runtime-ready.service"
                "ali-beets-catalog-ready.service"
              ];
            };
            validation = {
              enable = true;
              stagingDir = "${dataRoot}/staging";
              trackingFile = "${dataRoot}/beets-db/beets-validated.jsonl";
              verifiedLosslessTarget = "mp3 v0";
            };
          };
          web = {
            enable = true;
            hostName = "ali-music.ablz.au";
            inherit gatewayPort;
            gatewayAddresses = ["127.0.0.1" "10.88.0.1"];
            enableInsecure = true;
          };
          healthCheck.enable = false;
        };

        system.stateVersion = "25.11";
      };
    };

    systemd.services."container@ali-cratedigger" = {
      after = [
        "beets-runtime-ready.service"
        "cratedigger-secrets-split.service"
        "mnt-virtio.mount"
        "mnt-data.mount"
      ];
      requires = ["beets-runtime-ready.service" "cratedigger-secrets-split.service"];
      partOf = ["beets-runtime-ready.service" "cratedigger-secrets-split.service"];
      unitConfig.RequiresMountsFor = [dataRoot library slskdDownloadDir];
    };

    homelab.tailscaleShare.ali-music = {
      enable = true;
      fqdn = "ali-music.ablz.au";
      dataDir = "/mnt/virtio/tailscale-share/ali-music";
      upstream = "http://host.docker.internal:${toString gatewayPort}";
      hostname = "ali-music";
      tags = ["tag:share"];
      authKeySecret = null;
      firewallPorts = [gatewayPort];
      monitorName = "Ali Cratedigger (Tailnet)";
      monitorPath = "/healthz";
    };

    homelab.monitoring.errorPatterns = [];

    users.users.${operatorUser}.extraGroups = ["cratedigger-ops"];
  };
}
