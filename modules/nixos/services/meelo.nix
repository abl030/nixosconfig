{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.meelo;

  envFile = config.sops.secrets."meelo/env".path;

  allContainerServices = [
    "podman-meelo-db.service"
    "podman-meelo-mq.service"
    "podman-meelo-search.service"
    "podman-meelo-server.service"
    "podman-meelo-scanner.service"
    "podman-meelo-matcher.service"
    "podman-meelo-transcoder.service"
    "podman-meelo-front.service"
    "podman-meelo-nginx.service"
  ];

  # Nginx gateway config — envsubst replaces ${VAR} at container startup
  nginxTemplate = pkgs.writeText "meelo.conf.template" ''
    server {
        listen ''${PORT} default_server;
        listen [::]:''${PORT} default_server;
        access_log off;
        server_name _;
        client_max_body_size 0;

        location = /api {
            return 302 /api/;
        }
        location /api/ {
            proxy_pass ''${SERVER_URL}/;
        }
        location = /scanner {
            return 302 /scanner/;
        }
        location /scanner/ {
            proxy_pass ''${SCANNER_URL}/;
        }
        location = /matcher {
            return 302 /matcher/;
        }
        location /matcher/ {
            proxy_pass ''${MATCHER_URL}/;
        }
        location / {
            proxy_pass ''${FRONT_URL};
        }
    }
  '';

  # Default settings.json — user can replace at ${dataDir}/config/settings.json
  settingsJson = pkgs.writeText "meelo-settings.json" (builtins.toJSON {
    trackRegex = [
      # Artist/Album/01 - Track.ext  or  Artist/Album/1-01 Track.ext
      "/data/(?P<AlbumArtist>[^/]+)/(?P<Album>[^/]+)/(?:(?P<Disc>\\d+)-)?(?P<Index>\\d+)\\s*[.\\-]?\\s*(?P<Track>[^/]+?)\\.[^.]+$"
    ];
    metadata = {
      source = "embedded";
      order = "preferred";
      useExternalProviderGenres = true;
    };
    compilations = {
      artists = ["Various Artists" "Various" "VA"];
      useID3CompTag = true;
    };
    providers = [];
  });

  # Seed settings.json only if absent (preserves user edits)
  initConfig = pkgs.writeShellScript "meelo-init-config" ''
    if [ ! -f "${cfg.dataDir}/config/settings.json" ]; then
      cp ${settingsJson} "${cfg.dataDir}/config/settings.json"
      chmod 644 "${cfg.dataDir}/config/settings.json"
    fi
  '';
in {
  options.homelab.services.meelo = {
    enable = lib.mkEnableOption "Meelo music server (OCI containers)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/meelo";
      description = "Directory for Meelo persistent state.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Music";
      description = "Path to music library.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Host port for the Meelo web UI.";
    };

    tag = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = "Meelo image version tag.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."meelo/env" = {
      sopsFile = config.homelab.secrets.sopsFile "meelo.env";
      format = "dotenv";
    };

    homelab = {
      nfsWatchdog.podman-meelo-server.path = cfg.mediaDir;

      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-meelo-db.service";
          image = "docker.io/library/postgres:alpine3.14";
        }
        {
          unit = "podman-meelo-mq.service";
          image = "docker.io/library/rabbitmq:4.2-alpine";
        }
        {
          unit = "podman-meelo-search.service";
          image = "docker.io/getmeili/meilisearch:v1.5";
        }
        {
          unit = "podman-meelo-server.service";
          image = "docker.io/arthichaud/meelo-server:${cfg.tag}";
        }
        {
          unit = "podman-meelo-scanner.service";
          image = "docker.io/arthichaud/meelo-scanner:${cfg.tag}";
        }
        {
          unit = "podman-meelo-matcher.service";
          image = "docker.io/arthichaud/meelo-matcher:${cfg.tag}";
        }
        {
          unit = "podman-meelo-transcoder.service";
          image = "ghcr.io/zoriya/kyoo_transcoder:master";
        }
        {
          unit = "podman-meelo-front.service";
          image = "docker.io/arthichaud/meelo-front:${cfg.tag}";
        }
        {
          unit = "podman-meelo-nginx.service";
          image = "docker.io/library/nginx:1.29.4-alpine";
        }
      ];

      localProxy.hosts = [
        {
          host = "meelo.ablz.au";
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "Meelo";
          url = "https://meelo.ablz.au/";
        }
      ];
    };

    systemd = {
      services.podman-network-meelo = {
        description = "Create podman network for Meelo";
        before = allContainerServices;
        requiredBy = allContainerServices;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${config.virtualisation.podman.package}/bin/podman network create meelo --ignore";
        };
      };

      # Seed settings.json before server starts
      services.podman-meelo-server.serviceConfig.ExecStartPre =
        lib.mkBefore [initConfig];

      tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 root root - -"
        "d ${cfg.dataDir}/postgres 0755 root root - -"
        "d ${cfg.dataDir}/config 0755 root root - -"
        "d ${cfg.dataDir}/search 0755 root root - -"
        "d ${cfg.dataDir}/rabbitmq 0755 root root - -"
        "d ${cfg.dataDir}/transcoder_cache 0755 root root - -"
      ];
    };

    virtualisation.oci-containers.containers = {
      meelo-db = {
        image = "docker.io/library/postgres:alpine3.14";
        autoStart = true;
        pull = "newer";
        environmentFiles = [envFile];
        volumes = [
          "${cfg.dataDir}/postgres:/var/lib/postgresql/data"
        ];
        extraOptions = ["--network=meelo"];
      };

      meelo-mq = {
        image = "docker.io/library/rabbitmq:4.2-alpine";
        autoStart = true;
        pull = "newer";
        environmentFiles = [envFile];
        volumes = [
          "${cfg.dataDir}/rabbitmq:/var/lib/rabbitmq"
        ];
        extraOptions = ["--network=meelo" "--hostname=meelo-mq"];
      };

      meelo-search = {
        image = "docker.io/getmeili/meilisearch:v1.5";
        autoStart = true;
        pull = "newer";
        environmentFiles = [envFile];
        environment = {
          MEILI_ENV = "production";
          MEILI_LOG_LEVEL = "WARN";
        };
        volumes = [
          "${cfg.dataDir}/search:/meili_data"
        ];
        extraOptions = ["--network=meelo"];
      };

      meelo-server = {
        image = "docker.io/arthichaud/meelo-server:${cfg.tag}";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-db" "meelo-search" "meelo-mq"];
        environmentFiles = [envFile];
        environment = {
          TRANSCODER_URL = "http://meelo-transcoder:7666";
          MEILI_HOST = "http://meelo-search:7700";
          INTERNAL_DATA_DIR = "/data";
          INTERNAL_CONFIG_DIR = "/config";
        };
        volumes = [
          "${cfg.mediaDir}:/data"
          "${cfg.dataDir}/config:/config"
        ];
        extraOptions = ["--network=meelo" "--init"];
      };

      meelo-scanner = {
        image = "docker.io/arthichaud/meelo-scanner:${cfg.tag}";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-server"];
        environmentFiles = [envFile];
        environment = {
          API_URL = "http://meelo-server:4000";
          INTERNAL_DATA_DIR = "/data";
          INTERNAL_CONFIG_DIR = "/config";
        };
        volumes = [
          "${cfg.mediaDir}:/data:ro"
          "${cfg.dataDir}/config:/config:ro"
        ];
        extraOptions = ["--network=meelo"];
      };

      meelo-matcher = {
        image = "docker.io/arthichaud/meelo-matcher:${cfg.tag}";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-server" "meelo-mq"];
        environmentFiles = [envFile];
        environment = {
          API_URL = "http://meelo-server:4000";
          INTERNAL_CONFIG_DIR = "/config";
        };
        volumes = [
          "${cfg.dataDir}/config:/config:ro"
        ];
        extraOptions = ["--network=meelo"];
      };

      meelo-transcoder = {
        image = "ghcr.io/zoriya/kyoo_transcoder:master";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-db"];
        environmentFiles = [envFile];
        environment = {
          GOCODER_SAFE_PATH = "/data";
        };
        volumes = [
          "${cfg.mediaDir}:/data:ro"
          "${cfg.dataDir}/transcoder_cache:/cache"
        ];
        extraOptions = ["--network=meelo" "--cpus=1"];
      };

      meelo-front = {
        image = "docker.io/arthichaud/meelo-front:${cfg.tag}";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-server" "meelo-scanner"];
        environment = {
          PUBLIC_SERVER_URL = "https://meelo.ablz.au/api";
          SSR_SERVER_URL = "http://meelo-server:4000";
          PUBLIC_SCANNER_URL = "https://meelo.ablz.au/scanner";
          SSR_SCANNER_URL = "http://meelo-scanner:8133";
          PUBLIC_MATCHER_URL = "https://meelo.ablz.au/matcher";
          SSR_MATCHER_URL = "http://meelo-matcher:6789";
        };
        extraOptions = ["--network=meelo"];
      };

      meelo-nginx = {
        image = "docker.io/library/nginx:1.29.4-alpine";
        autoStart = true;
        pull = "newer";
        dependsOn = ["meelo-server" "meelo-front"];
        ports = ["${toString cfg.port}:5000"];
        environment = {
          PORT = "5000";
          FRONT_URL = "http://meelo-front:3000";
          SERVER_URL = "http://meelo-server:4000";
          SCANNER_URL = "http://meelo-scanner:8133";
          MATCHER_URL = "http://meelo-matcher:6789";
        };
        volumes = [
          "${nginxTemplate}:/etc/nginx/templates/meelo.conf.template:ro"
        ];
        extraOptions = ["--network=meelo"];
      };
    };
  };
}
