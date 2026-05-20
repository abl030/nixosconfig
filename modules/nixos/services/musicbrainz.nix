{
  config,
  inputs,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  # Operations: docs/wiki/services/musicbrainz.md
  cfg = config.homelab.services.musicbrainz;
  localIp = hostConfig.localIp or "127.0.0.1";
  pgpassSecret = config.sops.secrets."musicbrainz-pgpass".path;

  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "musicbrainz";
    hostNum = 10;
    dataDir = "${cfg.mirrorDir}/postgres-nspawn";
    passwordFile = pgpassSecret;
    pgPackage = pkgs.postgresql_18;
    extensions = _ps: [pkgs.musicbrainz-pg-amqp];
    pgSettings = {
      shared_buffers = "2GB";
      shared_preload_libraries = ["pg_amqp.so"];
    };
    extraDatabases = ["musicbrainz_db"];
    postStartSQLByDatabase.musicbrainz_db = ''
      CREATE EXTENSION IF NOT EXISTS cube;
      CREATE EXTENSION IF NOT EXISTS earthdistance;
      CREATE EXTENSION IF NOT EXISTS unaccent;
      CREATE EXTENSION IF NOT EXISTS amqp;
    '';
  };

  # --- lrclib image build (no public image available) ---
  lrclibPkg = pkgs.rustPlatform.buildRustPackage {
    pname = "lrclib";
    version = "0.1.0";
    src = inputs.lrclib-src;
    cargoLock.lockFile = "${inputs.lrclib-src}/Cargo.lock";
    buildInputs = [pkgs.sqlite];
    nativeBuildInputs = [pkgs.pkg-config];
  };

  lrclibImage = pkgs.dockerTools.buildLayeredImage {
    name = "lrclib-nix";
    tag = "latest";
    contents = [lrclibPkg pkgs.cacert];
    config = {
      Cmd = ["${lrclibPkg}/bin/lrclib" "serve" "--port" "3300" "--database" "/data/db.sqlite3"];
      ExposedPorts = {"3300/tcp" = {};};
      User = "65532:65532";
      Volumes = {"/data" = {};};
    };
  };

  mbTokenPath = "/run/secrets/musicbrainz-mb-token";
  envFile = config.sops.secrets."musicbrainz/env".path;

  musicbrainzImage = "docker.io/library/musicbrainz-musicbrainz:latest";
  indexerImage = "docker.io/library/musicbrainz-indexer:latest";
  mqImage = "docker.io/library/musicbrainz-mq:latest";
  searchImage = "docker.io/library/musicbrainz-docker_search:4.1.0";
  valkeyImage = "docker.io/valkey/valkey@sha256:aba3ce55601d0cf7e121fc3c5d9e23bea99bd0df5466500df46c157313226d2e";
  lrclibImageName = "lrclib-nix:latest";

  upstreamImageInputs = [
    musicbrainzImage
    indexerImage
    mqImage
    searchImage
  ];
  musicbrainzDockerRev = inputs.musicbrainz-docker.rev or inputs.musicbrainz-docker.lastModifiedDate or "source";

  containerNames = [
    "musicbrainz-valkey-1"
    "musicbrainz-mq-1"
    "musicbrainz-search-1"
    "musicbrainz-indexer-1"
    "musicbrainz-musicbrainz-1"
    "musicbrainz-lrclib-1"
  ];
  containerUnitNames = map (name: "podman-${name}") containerNames;
  containerServices = map (name: "${name}.service") containerUnitNames;

  retireComposeScript = pkgs.writeShellScript "musicbrainz-retire-compose" ''
    set -euo pipefail

    marker="${cfg.dataDir}/oci-migrated"
    if [ ! -e "$marker" ]; then
      for container in \
        musicbrainz-db-1 \
        musicbrainz-indexer-1 \
        musicbrainz-lrclib-1 \
        musicbrainz-mq-1 \
        musicbrainz-musicbrainz-1 \
        musicbrainz-redis-1 \
        musicbrainz-search-1 \
        musicbrainz-valkey-1
      do
        ${pkgs.podman}/bin/podman rm -f "$container" 2>/dev/null || true
      done

      ${pkgs.podman}/bin/podman network rm musicbrainz_default 2>/dev/null || true
      for volume in \
        musicbrainz_dbdump \
        musicbrainz_lmdconfig \
        musicbrainz_lrclib-data \
        musicbrainz_mqdata \
        musicbrainz_pgdata \
        musicbrainz_pghome \
        musicbrainz_solrdata \
        musicbrainz_solrdump
      do
        ${pkgs.podman}/bin/podman volume rm "$volume" 2>/dev/null || true
      done

      ${pkgs.coreutils}/bin/touch "$marker"
    fi

    ${pkgs.podman}/bin/podman network create musicbrainz --ignore
  '';

  buildImagesScript = pkgs.writeShellScript "musicbrainz-build-images" ''
    set -euo pipefail

    stamp_dir="${cfg.dataDir}/image-build-stamps"
    stamp="$stamp_dir/${musicbrainzDockerRev}"
    needs_build=0
    ${lib.concatMapStringsSep "\n" (image: ''
        ${pkgs.podman}/bin/podman image exists ${lib.escapeShellArg image} || needs_build=1
      '')
      upstreamImageInputs}

    if [ "$needs_build" = 0 ]; then
      ${pkgs.coreutils}/bin/install -d -m 0755 "$stamp_dir"
      ${pkgs.findutils}/bin/find "$stamp_dir" -mindepth 1 -maxdepth 1 -type f -delete
      ${pkgs.coreutils}/bin/touch "$stamp"
      exit 0
    fi

    ${pkgs.podman}/bin/podman build -t ${lib.escapeShellArg musicbrainzImage} ${inputs.musicbrainz-docker}/build/musicbrainz-prebuilt
    ${pkgs.podman}/bin/podman build -t ${lib.escapeShellArg indexerImage} ${inputs.musicbrainz-docker}/build/sir
    ${pkgs.podman}/bin/podman build -t ${lib.escapeShellArg mqImage} ${inputs.musicbrainz-docker}/build/rabbitmq
    ${pkgs.podman}/bin/podman build --build-arg MB_SOLR_VERSION=4.1.0 -t ${lib.escapeShellArg searchImage} ${inputs.musicbrainz-docker}/build/solr

    ${pkgs.coreutils}/bin/install -d -m 0755 "$stamp_dir"
    ${pkgs.findutils}/bin/find "$stamp_dir" -mindepth 1 -maxdepth 1 -type f -delete
    ${pkgs.coreutils}/bin/touch "$stamp"
  '';

  dbPasswordEnv = ''
    PASS=$(${pkgs.gnugrep}/bin/grep '^POSTGRES_PASSWORD=' ${pgpassSecret} | ${pkgs.coreutils}/bin/cut -d= -f2-)
    if [ -z "$PASS" ]; then
      echo "ERROR: POSTGRES_PASSWORD missing from ${pgpassSecret}" >&2
      exit 1
    fi
    export PGPASSWORD="$PASS"
  '';

  dbPreflightVerifyScript = pkgs.writeShellScript "musicbrainz-external-db-preflight" ''
    set -euo pipefail
    ${dbPasswordEnv}

    psql() {
      ${pkgs.postgresql_18}/bin/psql \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U musicbrainz \
        -d musicbrainz_db \
        -v ON_ERROR_STOP=1 \
        -tAc "$1"
    }

    require_true() {
      local label="$1"
      local sql="$2"
      local result
      result="$(psql "$sql")"
      if [ "$result" != "t" ]; then
        echo "ERROR: MusicBrainz DB verification failed: $label ($result)" >&2
        exit 1
      fi
    }

    require_true "artist/release tables are populated" \
      "SELECT (SELECT count(*) FROM artist) > 1000000 AND (SELECT count(*) FROM release) > 1000000"

    require_true "application tables are owned by musicbrainz" \
      "SELECT count(*) = 0 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_roles r ON r.oid = c.relowner WHERE c.relkind IN ('r','p','v','m','S','f') AND n.nspname NOT IN ('pg_catalog','information_schema') AND r.rolname <> 'musicbrainz'"
  '';

  dbVerifyScript = pkgs.writeShellScript "musicbrainz-external-db-verify" ''
    set -euo pipefail
    ${dbPreflightVerifyScript}
    ${dbPasswordEnv}

    psql() {
      ${pkgs.postgresql_18}/bin/psql \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U musicbrainz \
        -d musicbrainz_db \
        -v ON_ERROR_STOP=1 \
        -tAc "$1"
    }

    require_true() {
      local label="$1"
      local sql="$2"
      local result
      result="$(psql "$sql")"
      if [ "$result" != "t" ]; then
        echo "ERROR: MusicBrainz DB verification failed: $label ($result)" >&2
        exit 1
      fi
    }

    require_true "amqp extension exists" \
      "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'amqp')"

    require_true "amqp broker points at nspawn host bridge" \
      "SELECT EXISTS (SELECT 1 FROM amqp.broker WHERE host = '${pgc.hostAddress}' AND port = 5672)"

    require_true "SIR/indexer triggers exist" \
      "SELECT count(*) > 0 FROM pg_trigger WHERE NOT tgisinternal"
  '';

  amqpSetupScript = pkgs.writeShellScript "musicbrainz-amqp-setup" ''
    set -euo pipefail

    ${dbPreflightVerifyScript}
    if ${dbVerifyScript}; then
      exit 0
    fi

    ${dbPasswordEnv}

    psql_scalar() {
      ${pkgs.postgresql_18}/bin/psql \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U musicbrainz \
        -d musicbrainz_db \
        -v ON_ERROR_STOP=1 \
        -tAc "$1"
    }

    psql_exec() {
      ${pkgs.postgresql_18}/bin/psql \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U musicbrainz \
        -d musicbrainz_db \
        -v ON_ERROR_STOP=1 \
        -c "$1"
    }

    psql_file() {
      ${pkgs.postgresql_18}/bin/psql \
        -h ${pgc.dbHost} \
        -p ${toString pgc.dbPort} \
        -U musicbrainz \
        -d musicbrainz_db \
        -v ON_ERROR_STOP=1 \
        -f "$1"
    }

    tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$tmp"' EXIT

    wait_for_tcp() {
      local host="$1"
      local port="$2"
      for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
        if ${pkgs.bash}/bin/bash -c ":</dev/tcp/$host/$port" 2>/dev/null; then
          return 0
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
      echo "ERROR: timed out waiting for $host:$port" >&2
      return 1
    }

    wait_for_tcp ${pgc.hostAddress} 5672
    ${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 python -m sir amqp_setup

    if [ "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'amqp')")" != "t" ]; then
      ${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 sh -c 'MUSICBRAINZ_RABBITMQ_SERVER=${pgc.hostAddress} python -m sir extension'
      ${pkgs.podman}/bin/podman cp musicbrainz-indexer-1:/code/sql/CreateExtension.sql "$tmp/CreateExtension.sql"
      psql_file "$tmp/CreateExtension.sql"
    fi

    psql_exec "INSERT INTO amqp.broker (host, port) SELECT '${pgc.hostAddress}', 5672 WHERE NOT EXISTS (SELECT 1 FROM amqp.broker)"
    psql_exec "UPDATE amqp.broker SET host = '${pgc.hostAddress}', port = 5672"
    if [ "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM amqp.broker WHERE host = '${pgc.hostAddress}' AND port = 5672)")" != "t" ]; then
      echo "ERROR: MusicBrainz AMQP broker was not configured for ${pgc.hostAddress}:5672" >&2
      exit 1
    fi

    if [ "$(psql_scalar "SELECT count(*) > 0 FROM pg_trigger WHERE NOT tgisinternal")" != "t" ]; then
      ${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 python -m sir triggers
      ${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 ./GenerateDropSql.pl
      ${pkgs.podman}/bin/podman cp musicbrainz-indexer-1:/code/sql "$tmp/indexer-sql"
      ${pkgs.podman}/bin/podman cp "$tmp/indexer-sql" musicbrainz-musicbrainz-1:/tmp/indexer-sql
      ${pkgs.podman}/bin/podman exec musicbrainz-musicbrainz-1 indexer-triggers.sh /tmp/indexer-sql create
      ${pkgs.podman}/bin/podman exec musicbrainz-musicbrainz-1 rm -rf /tmp/indexer-sql
    fi

    ${dbVerifyScript}
  '';

  apiVerifyScript = pkgs.writeShellScript "musicbrainz-api-verify" ''
    set -euo pipefail
    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      response="$(
        ${pkgs.curl}/bin/curl -fsS \
          --connect-timeout 3 \
          --max-time 10 \
          -H 'User-Agent: musicbrainz-api-verify/1.0 (local homelab)' \
          --get \
          --data-urlencode 'query=artist:Radiohead AND release:"OK Computer"' \
          --data 'fmt=json' \
          --data 'limit=1' \
          "http://127.0.0.1:${toString cfg.webPort}/ws/2/release" 2>/dev/null
      )" && ${pkgs.jq}/bin/jq -e '((.count // 0) | tonumber) > 0 or ((.releases // []) | length > 0)' >/dev/null <<<"$response" && exit 0
      ${pkgs.coreutils}/bin/sleep 2
    done
    echo "ERROR: MusicBrainz /ws/2 representative lookup did not become healthy" >&2
    exit 1
  '';

  # Extract replication token from sops env file into standalone file for bind mount
  tokenExtractScript = pkgs.writeShellScript "musicbrainz-extract-token" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir -p /run/secrets
    token=$(${pkgs.gnugrep}/bin/grep '^REPLICATION_ACCESS_TOKEN=' ${envFile} | ${pkgs.coreutils}/bin/cut -d= -f2-)
    if [ -z "$token" ]; then
      echo "ERROR: REPLICATION_ACCESS_TOKEN not found in ${envFile}" >&2
      exit 1
    fi
    printf '%s' "$token" > ${mbTokenPath}
    ${pkgs.coreutils}/bin/chmod 600 ${mbTokenPath}
  '';
in {
  options.homelab.services.musicbrainz = {
    enable = lib.mkEnableOption "MusicBrainz mirror with LRCLIB lyrics";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/musicbrainz";
      description = "Directory for backed-up app state (mqdata).";
    };

    mirrorDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/musicbrainz-mirrors";
      description = "Directory for re-downloadable mirror data (pgdata, solrdata, lrclib). Should NOT be backed up.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 5200;
      description = "Port for the MusicBrainz web interface.";
    };

    lrclibPort = lib.mkOption {
      type = lib.types.port;
      default = 3300;
      description = "Port for the LRCLIB lyrics service.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "musicbrainz.service";
          image = valkeyImage;
        }
      ];

      monitoring.monitors = [
        {
          name = "LRCLIB";
          url = "http://${localIp}:${toString cfg.lrclibPort}/api/search?artist_name=Radiohead&track_name=Creep";
        }
      ];

      # See #253 audit + rules-doc "Per-service errorPatterns".
      # Skipped containers: musicbrainz-musicbrainz-1 (only webpack
      # progress noise) and musicbrainz-valkey-1 (silent in 30d) — both
      # surface via the LRCLIB Kuma monitor.
      monitoring.errorPatterns = [
        {
          name = "MusicBrainz post-deploy verification failed";
          unit = "musicbrainz.service";
          # Catches DB-verification + /ws/2 health check refusals from
          # the orchestration script. Historical compose orchestration
          # errors won't recur (compose retired 2026-04-16).
          pattern = "(?i)MusicBrainz (?:DB verification failed|.*did not become healthy)|build images failed";
          severity = "critical";
          summary = "musicbrainz orchestration's post-deploy verification failed";
        }
        {
          name = "MusicBrainz indexer DNS plane failure";
          unit = "podman-musicbrainz-indexer-1.service";
          # podman/aardvark DNS plane failure affects all MB containers.
          pattern = "(?i)aardvark-dns failed to start";
          severity = "warning";
          summary = "podman DNS plane is unhealthy — MB containers can't resolve each other";
        }
        {
          name = "MusicBrainz Solr proxy failure";
          unit = "podman-musicbrainz-search-1.service";
          # Solr emits "Error trying to proxy request" routinely for
          # ~30s after container restart while the replica peer
          # reconnects (caught a false positive 2026-05-20 immediately
          # after a deploy). Require sustained errors (>3 in 5m) to
          # distinguish the transient startup cascade from a genuine
          # partial-outage. Single transient 500s are now silent.
          pattern = "(?i)SolrException.*Error trying to proxy request|Connection pool shut down";
          severity = "warning";
          summary = "Solr search container is failing to proxy (sustained)";
          threshold = 3;
        }
      ];
    };

    sops.secrets."musicbrainz/env" = {
      sopsFile = config.homelab.secrets.sopsFile "musicbrainz.env";
      format = "dotenv";
    };

    sops.secrets."musicbrainz-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "musicbrainz-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    containers.musicbrainz-db = pgc.containerConfig;

    networking.firewall.allowedTCPPorts = [cfg.webPort cfg.lrclibPort];

    virtualisation.oci-containers.containers = {
      musicbrainz-valkey-1 = {
        image = valkeyImage;
        autoStart = false;
        pull = "newer";
        extraOptions = ["--network=musicbrainz" "--network-alias=valkey"];
      };

      musicbrainz-mq-1 = {
        image = mqImage;
        autoStart = false;
        pull = "never";
        ports = ["${pgc.hostAddress}:5672:5672"];
        volumes = ["${cfg.dataDir}/mqdata:/var/lib/rabbitmq"];
        extraOptions = ["--network=musicbrainz" "--network-alias=mq" "--hostname=mq"];
      };

      musicbrainz-search-1 = {
        image = searchImage;
        autoStart = false;
        pull = "never";
        environment = {
          SOLR_HEAP = "2g";
          LOG4J_FORMAT_MSG_NO_LOOKUPS = "true";
        };
        volumes = [
          "${cfg.mirrorDir}/dbdump:/media/dbdump:ro"
          "${cfg.mirrorDir}/solrdata:/var/solr"
          "${cfg.mirrorDir}/solrdump:/var/cache/musicbrainz/solr-backups"
        ];
        extraOptions = ["--network=musicbrainz" "--network-alias=search" "--memory-swappiness=-1"];
      };

      musicbrainz-indexer-1 = {
        image = indexerImage;
        autoStart = false;
        pull = "never";
        dependsOn = ["musicbrainz-mq-1" "musicbrainz-search-1"];
        environmentFiles = [pgpassSecret];
        environment = {
          POSTGRES_USER = "musicbrainz";
          MUSICBRAINZ_POSTGRES_SERVER = pgc.dbHost;
          MUSICBRAINZ_POSTGRES_READONLY_SERVER = pgc.dbHost;
          MUSICBRAINZ_RABBITMQ_SERVER = "mq";
          MUSICBRAINZ_SEARCH_SERVER = "search:8983/solr";
        };
        volumes = ["${inputs.musicbrainz-docker}/default/indexer.ini:/code/config.ini:ro"];
        extraOptions = ["--network=musicbrainz" "--network-alias=indexer"];
      };

      musicbrainz-musicbrainz-1 = {
        image = musicbrainzImage;
        autoStart = false;
        pull = "never";
        dependsOn = ["musicbrainz-mq-1" "musicbrainz-search-1" "musicbrainz-valkey-1"];
        ports = ["${toString cfg.webPort}:5000"];
        environmentFiles = [pgpassSecret];
        environment = {
          POSTGRES_USER = "musicbrainz";
          MUSICBRAINZ_POSTGRES_SERVER = pgc.dbHost;
          MUSICBRAINZ_POSTGRES_READONLY_SERVER = pgc.dbHost;
          MUSICBRAINZ_REDIS_SERVER = "valkey";
          MUSICBRAINZ_VALKEY_SERVER = "valkey";
          MUSICBRAINZ_WEB_SERVER_HOST = localIp;
          MUSICBRAINZ_WEB_SERVER_PORT = toString cfg.webPort;
          MUSICBRAINZ_BASE_FTP_URL = "";
          MUSICBRAINZ_BASE_DOWNLOAD_URL = "https://data.metabrainz.org/pub/musicbrainz";
          MUSICBRAINZ_SERVER_PROCESSES = "10";
          MUSICBRAINZ_USE_PROXY = "1";
        };
        volumes = [
          "${cfg.mirrorDir}/dbdump:/media/dbdump"
          "${cfg.mirrorDir}/solrdump:/var/cache/musicbrainz/solr-backups:ro"
          "${mbTokenPath}:/run/secrets/metabrainz_access_token:ro"
        ];
        extraOptions = ["--network=musicbrainz" "--network-alias=musicbrainz"];
      };

      musicbrainz-lrclib-1 = {
        image = lrclibImageName;
        imageFile = lrclibImage;
        autoStart = false;
        pull = "never";
        ports = ["${toString cfg.lrclibPort}:3300"];
        volumes = ["${cfg.mirrorDir}/lrclib:/data"];
        extraOptions = ["--network=musicbrainz" "--network-alias=lrclib" "--user=65532:65532"];
      };
    };

    systemd = {
      services = lib.mkMerge [
        {
          musicbrainz-retire-compose = {
            description = "Retire legacy MusicBrainz compose containers";
            before = containerServices;
            requiredBy = containerServices;
            after = ["podman.service"];
            requires = ["podman.service"];
            unitConfig.RequiresMountsFor = [cfg.dataDir cfg.mirrorDir];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = retireComposeScript;
            };
          };

          musicbrainz-build-images = {
            description = "Build upstream MusicBrainz OCI images";
            before = containerServices;
            requiredBy = containerServices;
            after = ["podman.service" "musicbrainz-retire-compose.service"];
            requires = ["podman.service" "musicbrainz-retire-compose.service"];
            unitConfig.RequiresMountsFor = [cfg.dataDir];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = buildImagesScript;
            };
          };

          musicbrainz-token = {
            description = "Extract MusicBrainz replication token for container bind mount";
            before = ["podman-musicbrainz-musicbrainz-1.service"];
            requiredBy = ["podman-musicbrainz-musicbrainz-1.service"];
            after = ["sops-install-secrets.service"];
            wants = ["sops-install-secrets.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = tokenExtractScript;
            };
          };

          musicbrainz = {
            description = "MusicBrainz Mirror + LRCLIB stack readiness";
            after = ["network-online.target" "container@musicbrainz-db.service"] ++ containerServices;
            wants = ["network-online.target"];
            requires = ["container@musicbrainz-db.service"] ++ containerServices;
            wantedBy = ["multi-user.target"];
            unitConfig.RequiresMountsFor = [cfg.dataDir cfg.mirrorDir];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              TimeoutStartSec = "600s";
            };

            preStart = ''
              ${dbPreflightVerifyScript}
            '';

            script = ''
              true
            '';

            restartTriggers =
              [
                lrclibImage
                dbPreflightVerifyScript
                dbVerifyScript
                amqpSetupScript
                apiVerifyScript
                pgpassSecret
                tokenExtractScript
                retireComposeScript
                buildImagesScript
                config.systemd.units."container@musicbrainz-db.service".unit
                config.systemd.units."musicbrainz-token.service".unit
              ]
              ++ map (unit: config.systemd.units.${unit}.unit) containerServices;

            postStart = ''
              ${amqpSetupScript}
              ${apiVerifyScript}
              ${dbVerifyScript}
            '';
          };

          # Daily replication — pulls latest MusicBrainz data
          musicbrainz-replication = {
            description = "MusicBrainz daily replication";
            after = ["musicbrainz.service"];
            requires = ["musicbrainz.service"];
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "3600s";
              ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-musicbrainz-1 replication.sh";
            };
          };

          # Weekly Solr reindex — rebuilds search index
          musicbrainz-reindex = {
            description = "MusicBrainz weekly Solr reindex";
            after = ["musicbrainz.service"];
            requires = ["musicbrainz.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 python -m sir reindex --entity-type artist --entity-type release";
            };
          };
        }
        (lib.genAttrs containerUnitNames (_: {
          partOf = ["musicbrainz.service"];
          after = ["musicbrainz-retire-compose.service" "musicbrainz-build-images.service"];
          requires = ["musicbrainz-retire-compose.service" "musicbrainz-build-images.service"];
          unitConfig.RequiresMountsFor = [cfg.dataDir cfg.mirrorDir];
        }))
        {
          podman-musicbrainz-musicbrainz-1 = {
            after = ["musicbrainz-token.service"];
            requires = ["musicbrainz-token.service"];
          };

          # mq binds to ${pgc.hostAddress}:5672 — the host-side veth IP of the
          # musicbrainz-db nspawn. Without an explicit ordering dep, parallel
          # restart during switch-to-configuration races: mq tries to bind
          # before the veth exists and burns through StartLimitBurst.
          podman-musicbrainz-mq-1 = {
            after = ["container@musicbrainz-db.service"];
            requires = ["container@musicbrainz-db.service"];
            serviceConfig.RestartSec = "5s";
            unitConfig = {
              StartLimitIntervalSec = "120s";
              StartLimitBurst = "10";
            };
          };
        }
      ];

      timers = {
        musicbrainz-replication = {
          description = "MusicBrainz daily replication timer";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "*-*-* 03:00:00";
            Persistent = true;
          };
        };

        musicbrainz-reindex = {
          description = "MusicBrainz weekly Solr reindex timer";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "Sun 01:00";
            Persistent = true;
          };
        };
      };

      tmpfiles.rules = [
        # Backed-up data (small, operational)
        "d ${cfg.dataDir} 0755 root root - -"
        "d ${cfg.dataDir}/mqdata 0755 root root - -"
        # Mirror data (large, re-downloadable, NOT backed up)
        "d ${cfg.mirrorDir} 0755 root root - -"
        "d ${cfg.mirrorDir}/postgres-nspawn 0755 root root - -"
        "d ${cfg.mirrorDir}/postgres-nspawn/postgres 0700 root root - -"
        "d ${cfg.mirrorDir}/solrdata 0755 root root - -"
        "d ${cfg.mirrorDir}/dbdump 0755 root root - -"
        "d ${cfg.mirrorDir}/solrdump 0755 root root - -"
        "d ${cfg.mirrorDir}/lrclib 0750 65532 65532 - -"
        "Z ${cfg.mirrorDir}/lrclib 0750 65532 65532 - -"
      ];
    };
  };
}
