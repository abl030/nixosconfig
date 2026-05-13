{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.meelo;

  envFile = config.sops.secrets."meelo/env".path;
  pgpassFile = config.sops.secrets."meelo-pgpass".path;

  # PostgreSQL 14 matches the existing bundled postgres:alpine3.14 cluster.
  # Do not make the extraction also be a database major upgrade.
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "meelo";
    hostNum = 8;
    dataDir = "${cfg.dataDir}/postgres-nspawn";
    passwordFile = "/run/secrets/meelo-pgpass";
    pgPackage = pkgs.postgresql_14;
    # Meelo runs Prisma migrations at startup and needs a shadow database.
    # This is scoped to the isolated Meelo PostgreSQL container.
    postStartSQL = ''
      ALTER ROLE "meelo" CREATEDB;
    '';
  };

  allContainerServices = [
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

  # Declarative settings.json with placeholder tokens for API keys
  settingsJson = pkgs.writeText "meelo-settings.json" (builtins.toJSON {
    trackRegex = [
      # Standard Beets: <library>/Artist/YYYY - Album/NN Track.ext
      # Release (not Album) from path — embedded tags provide Album, path provides Release for aunique disambiguation
      "/data/[^/]+/(?P<AlbumArtist>[^/]+)/(?:[^/]*\\s-\\s)?(?P<Release>[^/]+)/(?:(?P<Disc>\\d+)-)?(?P<Index>\\d+)\\s*[.\\-]?\\s*(?P<Track>[^/]+?)\\.[^.]+$"
      # Compilations: <library>/Compilations/Album/NN Track.ext
      "/data/[^/]+/Compilations/(?P<Release>[^/]+)/(?:(?P<Disc>\\d+)-)?(?P<Index>\\d+)\\s*[.\\-]?\\s*(?P<Track>[^/]+?)\\.[^.]+$"
      # Singletons: <library>/Non-Album/Artist/Track.ext
      "/data/[^/]+/Non-Album/(?P<AlbumArtist>[^/]+)/(?P<Track>[^/]+?)\\.[^.]+$"
      # Live/mix recordings: Live/Artist/Album/Track.ext (no track index)
      "/data/Live/(?P<AlbumArtist>[^/]+)/(?P<Release>[^/]+)/(?P<Track>[^/]+?)\\.[^.]+$"
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
    providers = {
      musicbrainz = {};
      wikipedia = {};
      allmusic = {};
      metacritic = {};
      lrclib = {};
      discogs = {apiKey = "__DISCOGS_TOKEN__";};
      genius = {apiKey = "__GENIUS_TOKEN__";};
    };
  });

  # Template settings.json: copy from nix store, substitute API keys from sops env
  initConfig = pkgs.writeShellScript "meelo-init-config" ''
    cp ${settingsJson} "${cfg.dataDir}/config/settings.json"
    chmod 644 "${cfg.dataDir}/config/settings.json"

    # Source API keys from sops env file and substitute placeholders
    set -a
    . "${envFile}"
    set +a
    ${pkgs.gnused}/bin/sed -i \
      -e "s|__DISCOGS_TOKEN__|''${DISCOGS_TOKEN:-}|g" \
      -e "s|__GENIUS_TOKEN__|''${GENIUS_TOKEN:-}|g" \
      "${cfg.dataDir}/config/settings.json"
  '';

  podman = "${config.virtualisation.podman.package}/bin/podman";

  waitForPostgres = pkgs.writeShellScript "meelo-wait-for-postgres" ''
    for i in $(seq 1 60); do
      if ${lib.getExe' pkgs.postgresql_14 "pg_isready"} \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U meelo \
        -d meelo >/dev/null 2>&1; then
        echo "PostgreSQL is ready"
        exit 0
      fi
      echo "Waiting for PostgreSQL... ($i/60)"
      sleep 1
    done

    echo "PostgreSQL not ready after 60s"
    exit 1
  '';

  # Wait for MeiliSearch to be healthy and cancel any stale task backlog.
  # Meelo's server has a hardcoded 5s waitForTask timeout; if MeiliSearch has
  # enqueued tasks from previous crash-loop restarts, the server's indexCreation
  # task lands at the back of the queue and times out, causing another crash.
  waitForMeili = let
    meiliUrl = "http://127.0.0.1:7700";
    wget = "${pkgs.wget}/bin/wget";
  in
    pkgs.writeShellScript "meelo-wait-for-meili" ''
      MEILI_KEY=$(${pkgs.gnugrep}/bin/grep -oP 'MEILI_MASTER_KEY=\K.*' "${envFile}" || true)

      for i in $(seq 1 30); do
        if ${podman} exec meelo-search ${wget} -qO- ${meiliUrl}/health 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -q available; then
          echo "MeiliSearch is ready"

          # Cancel any enqueued tasks to prevent backlog-induced timeout
          PENDING=$(${podman} exec meelo-search ${wget} -qO- \
            --header="Authorization: Bearer $MEILI_KEY" \
            "${meiliUrl}/tasks?statuses=enqueued&limit=1" 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP '"total":\K\d+' || echo "0")

          if [ "$PENDING" -gt 0 ] 2>/dev/null; then
            echo "Cancelling $PENDING stale enqueued MeiliSearch tasks"
            ${podman} exec meelo-search ${wget} -qO- --post-data="" \
              --header="Authorization: Bearer $MEILI_KEY" \
              "${meiliUrl}/tasks/cancel?statuses=enqueued" 2>/dev/null || true
            sleep 2
          fi
          exit 0
        fi
        echo "Waiting for MeiliSearch... ($i/30)"
        sleep 2
      done
      echo "MeiliSearch not ready after 60s, starting anyway"
    '';

  apkDir = "${cfg.dataDir}/apk";
  obtainiumAdditionalSettings = builtins.toJSON {
    intermediateLink = [];
    customLinkFilterRegex = "";
    filterByLinkText = false;
    matchLinksOutsideATags = false;
    skipSort = false;
    reverseSort = false;
    sortByLastLinkSegment = true;
    versionExtractWholePage = false;
    defaultPseudoVersioningMethod = "partialAPKHash";
    trackOnly = false;
    versionExtractionRegEx = "v\\d+\\.\\d+\\.\\d+";
    matchGroupToUse = "";
    versionDetection = false;
    useVersionCodeAsOSVersion = false;
    apkFilterRegEx = "meelo-v\\d+\\.\\d+\\.\\d+\\.apk$";
    invertAPKFilter = false;
    autoApkFilterByArch = false;
    appName = "Meelo";
    appAuthor = "ArtiChaud";
    refreshBeforeDownload = false;
  };
  obtainiumApp = builtins.toJSON {
    id = "dev.artichaud.meelo";
    url = "https://meelo.ablz.au/apk/";
    author = "meelo.ablz.au";
    name = "Meelo";
    preferredApkIndex = 0;
    additionalSettings = obtainiumAdditionalSettings;
    overrideSource = null;
  };
  obtainiumUri = "obtainium://app/${lib.escapeURL obtainiumApp}";
  obtainiumRedirectUrl = "https://apps.obtainium.imranr.dev/redirect?r=${lib.escapeURL obtainiumUri}";
  apkMirrorScript = pkgs.writeShellScript "meelo-apk-mirror" ''
    set -euo pipefail

    repo="Arthi-chaud/Meelo"
    api="https://api.github.com/repos/$repo/releases/latest"
    dir=${lib.escapeShellArg apkDir}

    ${pkgs.coreutils}/bin/mkdir -p "$dir"

    release_json=$(${pkgs.curl}/bin/curl \
      -fsSL \
      --retry 3 \
      --retry-all-errors \
      --connect-timeout 20 \
      "$api")

    tag=$(printf '%s' "$release_json" | ${pkgs.jq}/bin/jq -r '.tag_name // empty')
    url=$(printf '%s' "$release_json" | ${pkgs.jq}/bin/jq -r '.assets[] | select(.name == "meelo.apk") | .browser_download_url' | ${pkgs.coreutils}/bin/head -n1)
    expected_size=$(printf '%s' "$release_json" | ${pkgs.jq}/bin/jq -r '.assets[] | select(.name == "meelo.apk") | .size' | ${pkgs.coreutils}/bin/head -n1)

    if [[ -z "$tag" || -z "$url" || -z "$expected_size" || "$url" == "null" ]]; then
      echo "meelo-apk-mirror: latest release is missing meelo.apk metadata" >&2
      exit 1
    fi

    safe_tag=$(${pkgs.coreutils}/bin/printf '%s' "$tag" | ${pkgs.gnused}/bin/sed 's/[^A-Za-z0-9._-]/_/g')
    versioned_apk="$dir/meelo-$safe_tag.apk"

    if [[ -f "$versioned_apk" ]]; then
      current_size=$(${pkgs.coreutils}/bin/stat -c %s "$versioned_apk")
      if [[ "$current_size" == "$expected_size" ]]; then
        echo "meelo-apk-mirror: $tag already downloaded"
      else
        ${pkgs.coreutils}/bin/rm -f "$versioned_apk"
      fi
    fi

    if [[ ! -f "$versioned_apk" ]]; then
      tmp=$(${pkgs.coreutils}/bin/mktemp "$dir/.meelo.apk.XXXXXX")
      cleanup() {
        ${pkgs.coreutils}/bin/rm -f "$tmp"
      }
      trap cleanup EXIT

      ${pkgs.curl}/bin/curl \
        -fL \
        --retry 5 \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 900 \
        --output "$tmp" \
        "$url"

      actual_size=$(${pkgs.coreutils}/bin/stat -c %s "$tmp")
      if [[ "$actual_size" != "$expected_size" ]]; then
        echo "meelo-apk-mirror: size mismatch for $tag: expected $expected_size, got $actual_size" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "$versioned_apk"
      trap - EXIT
    fi

    sha256=$(${pkgs.coreutils}/bin/sha256sum "$versioned_apk" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    ${pkgs.findutils}/bin/find "$dir" -maxdepth 1 -type f -name 'meelo-*.apk' ! -name "meelo-$safe_tag.apk" -delete
    ${pkgs.coreutils}/bin/ln -f "$versioned_apk" "$dir/meelo.apk"

    ${pkgs.coreutils}/bin/printf '%s\n' "$tag" > "$dir/latest.version"
    ${pkgs.coreutils}/bin/printf '{"tag":"%s","url":"https://meelo.ablz.au/apk/meelo-%s.apk","latestUrl":"https://meelo.ablz.au/apk/meelo.apk","size":%s,"sha256":"%s"}\n' \
      "$tag" "$safe_tag" "$expected_size" "$sha256" > "$dir/latest.json"
    ${pkgs.coreutils}/bin/printf '%s\n' \
      '<!doctype html>' \
      '<html>' \
      '  <head><title>Meelo Android APK</title></head>' \
      '  <body>' \
      "    <p>Latest: $tag</p>" \
      '    <p><a href="${obtainiumRedirectUrl}">Add or update Meelo in Obtainium</a></p>' \
      "    <a href=\"meelo-$safe_tag.apk\">meelo-$tag.apk</a>" \
      '    <p>Version regex: <code>v\d+\.\d+\.\d+</code></p>' \
      '  </body>' \
      '</html>' \
      > "$dir/index.html"
    ${pkgs.coreutils}/bin/chmod 0644 "$dir/latest.version" "$dir/latest.json" "$dir/index.html" "$dir/meelo.apk" "$versioned_apk"

    echo "meelo-apk-mirror: mirrored $tag ($expected_size bytes, sha256=$sha256)"
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
    # Narrow DB password file for the nspawn PostgreSQL container and the
    # Meelo consumers that actually connect to it. The broad meelo/env file
    # still carries non-DB app secrets (RabbitMQ, Meili, JWT, API keys).
    sops.secrets."meelo-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "meelo-pgpass.env";
      format = "dotenv";
      mode = "0444";
    };

    containers.meelo-db = pgc.containerConfig;

    homelab = {
      nfsWatchdog.podman-meelo-server.path = cfg.mediaDir;

      podman.enable = true;
      podman.containers = [
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
      services = {
        podman-network-meelo = {
          description = "Create podman network for Meelo";
          before = allContainerServices;
          requiredBy = allContainerServices;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${config.virtualisation.podman.package}/bin/podman network create meelo --ignore";
          };
        };

        podman-meelo-server = {
          after = ["container@meelo-db.service"];
          requires = ["container@meelo-db.service"];
          restartTriggers = [
            config.systemd.units."container@meelo-db.service".unit
            pgpassFile
          ];
          # Wait for MeiliSearch + template settings.json before server starts
          serviceConfig.ExecStartPre = lib.mkBefore [waitForPostgres waitForMeili initConfig];
        };

        podman-meelo-transcoder = {
          after = ["container@meelo-db.service"];
          requires = ["container@meelo-db.service"];
          restartTriggers = [
            config.systemd.units."container@meelo-db.service".unit
            pgpassFile
          ];
          serviceConfig.ExecStartPre = lib.mkBefore [waitForPostgres];
        };

        meelo-apk-mirror = {
          description = "Mirror latest Meelo Android APK for stable Obtainium downloads";
          wants = ["network-online.target"];
          after = ["network-online.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = apkMirrorScript;
          };
        };
      };

      timers.meelo-apk-mirror = {
        description = "Refresh mirrored Meelo Android APK";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "10min";
          OnCalendar = "*-*-* 03:30:00";
          Persistent = true;
          RandomizedDelaySec = "30min";
          Unit = "meelo-apk-mirror.service";
        };
      };

      tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 root root - -"
        "d ${apkDir} 0755 root root - -"
        "d ${cfg.dataDir}/postgres-nspawn 0755 root root - -"
        "d ${cfg.dataDir}/postgres-nspawn/postgres 0700 root root - -"
        "d ${cfg.dataDir}/config 0755 root root - -"
        "d ${cfg.dataDir}/search 0755 root root - -"
        "d ${cfg.dataDir}/rabbitmq 0755 root root - -"
        "d ${cfg.dataDir}/transcoder_cache 0755 root root - -"
      ];
    };

    services.nginx.virtualHosts."meelo.ablz.au".locations."/apk/" = {
      root = cfg.dataDir;
      extraConfig = ''
        types {
          application/vnd.android.package-archive apk;
          application/json json;
          text/html html;
          text/plain version;
        }
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=300";
        try_files $uri $uri/index.html =404;
      '';
    };

    virtualisation.oci-containers.containers = {
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
        dependsOn = ["meelo-search" "meelo-mq"];
        # pgpassFile comes last so DATABASE_URL/PG* values override any
        # temporary rollback-era DB keys still present in meelo/env.
        environmentFiles = [envFile pgpassFile];
        environment = {
          TRANSCODER_URL = "http://meelo-transcoder:7666";
          MEILI_HOST = "http://meelo-search:7700";
          INTERNAL_DATA_DIR = "/data";
          INTERNAL_CONFIG_DIR = "/config";
        };
        volumes = [
          "${cfg.mediaDir}:/data:ro"
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
        environmentFiles = [pgpassFile];
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
        dependsOn = ["meelo-server" "meelo-front" "meelo-matcher" "meelo-scanner"];
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
