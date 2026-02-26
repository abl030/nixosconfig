{
  config,
  inputs,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.musicbrainz;
  localIp = hostConfig.localIp or "127.0.0.1";

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
      Volumes = {"/data" = {};};
    };
  };

  # --- Compose files ---
  baseCompose = "${inputs.musicbrainz-docker}/docker-compose.yml";

  # All named volume bind mounts — mirrors vs backed-up split
  volumeOverride = pkgs.writeText "musicbrainz-volumes.yml" ''
    volumes:
      mqdata:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.dataDir}/mqdata
          o: bind
      pgdata:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/pgdata
          o: bind
      solrdata:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/solrdata
          o: bind
      dbdump:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/dbdump
          o: bind
      solrdump:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/solrdump
          o: bind
      lmdconfig:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.dataDir}/lmdconfig
          o: bind
      lrclib-data:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/lrclib
          o: bind
  '';

  # Postgres tuning, credentials, Solr heap, MB web server host
  settingsOverride = pkgs.writeText "musicbrainz-settings.yml" ''
    services:
      musicbrainz:
        environment:
          POSTGRES_USER: "abc"
          POSTGRES_PASSWORD: "abc"
          MUSICBRAINZ_WEB_SERVER_HOST: "${localIp}"
      db:
        environment:
          POSTGRES_USER: "abc"
          POSTGRES_PASSWORD: "abc"
        command: postgres -c "shared_buffers=2GB" -c "shared_preload_libraries=pg_amqp.so"
      indexer:
        environment:
          POSTGRES_USER: "abc"
          POSTGRES_PASSWORD: "abc"
      search:
        mem_swappiness: -1
        environment:
          - SOLR_HEAP=2g
  '';

  # LMD, Redis, LRCLIB service definitions
  lmdOverride = pkgs.writeText "musicbrainz-lmd.yml" ''
    services:
      redis:
        image: docker.io/library/redis:7-alpine
        restart: unless-stopped

      lmd:
        image: blampe/lidarr.metadata:70a9707
        ports:
          - "${toString cfg.lmdPort}:5001"
        environment:
          DEBUG: "false"
          PRODUCTION: "false"
          USE_CACHE: "true"
          ENABLE_STATS: "false"
          ROOT_PATH: ""
          IMAGE_CACHE_HOST: "theaudiodb.com"
          EXTERNAL_TIMEOUT: "1000"
          INVALIDATE_APIKEY: ""
          REDIS_HOST: "redis"
          REDIS_PORT: "6379"
          FANART_KEY: "''${FANART_KEY}"
          PROVIDERS__FANARTTVPROVIDER__0__0: "''${FANART_KEY}"
          SPOTIFY_ID: "''${SPOTIFY_ID}"
          SPOTIFY_SECRET: "''${SPOTIFY_SECRET}"
          SPOTIFY_REDIRECT_URL: "http://${localIp}:${toString cfg.lmdPort}"
          PROVIDERS__SPOTIFYPROVIDER__1__CLIENT_ID: "''${SPOTIFY_ID}"
          PROVIDERS__SPOTIFYPROVIDER__1__CLIENT_SECRET: "''${SPOTIFY_SECRET}"
          PROVIDERS__SPOTIFYAUTHPROVIDER__1__CLIENT_ID: "''${SPOTIFY_ID}"
          PROVIDERS__SPOTIFYAUTHPROVIDER__1__CLIENT_SECRET: "''${SPOTIFY_SECRET}"
          PROVIDERS__SPOTIFYAUTHPROVIDER__1__REDIRECT_URI: "http://${localIp}:${toString cfg.lmdPort}"
          TADB_KEY: "2"
          PROVIDERS__THEAUDIODBPROVIDER__0__0: "2"
          LASTFM_KEY: "''${LASTFM_KEY}"
          LASTFM_SECRET: "''${LASTFM_SECRET}"
          PROVIDERS__SOLRSEARCHPROVIDER__1__SEARCH_SERVER: "http://search:8983/solr"
        restart: unless-stopped
        volumes:
          - lmdconfig:/config
        depends_on:
          - db
          - mq
          - search
          - redis

      lrclib:
        container_name: musicbrainz-lrclib-1
        ports:
          - "${toString cfg.lrclibPort}:3300"
        volumes:
          - lrclib-data:/data
        restart: unless-stopped
  '';

  mbTokenPath = "/run/secrets/musicbrainz-mb-token";

  replicationTokenOverride = pkgs.writeText "musicbrainz-replication-token.yml" ''
    services:
      musicbrainz:
        volumes:
          - ${mbTokenPath}:/run/secrets/metabrainz_access_token:ro
  '';

  # Set lrclib to use our Nix-built image
  lrclibImageOverride = pkgs.writeText "musicbrainz-lrclib-image.yml" ''
    services:
      lrclib:
        image: lrclib-nix:latest
  '';

  envFile = config.sops.secrets."musicbrainz/env".path;

  composeFiles = [
    baseCompose
    volumeOverride
    settingsOverride
    lmdOverride
    replicationTokenOverride
    lrclibImageOverride
  ];
  composeFlags = lib.concatMapStringsSep " " (f: "-f ${f}") composeFiles;

  composeScript = pkgs.writeShellScript "musicbrainz-compose" ''
    exec ${pkgs.podman}/bin/podman compose \
      --project-name musicbrainz \
      ${composeFlags} \
      --env-file ${envFile} \
      "$@"
  '';

  # Extract replication token from sops env file into standalone file for bind mount
  tokenExtractScript = pkgs.writeShellScript "musicbrainz-extract-token" ''
    set -euo pipefail
    mkdir -p /run/secrets
    token=$(grep '^REPLICATION_ACCESS_TOKEN=' ${envFile} | cut -d= -f2-)
    if [ -z "$token" ]; then
      echo "ERROR: REPLICATION_ACCESS_TOKEN not found in ${envFile}" >&2
      exit 1
    fi
    printf '%s' "$token" > ${mbTokenPath}
    chmod 600 ${mbTokenPath}
  '';

  # LMD cache DB init — creates database and schema in the MB postgres instance
  lmCacheInitSql = pkgs.writeText "lm-cache-init.sql" ''
    -- LMD cache schema (idempotent)
    CREATE OR REPLACE FUNCTION cache_updated() RETURNS TRIGGER AS $body$
    BEGIN NEW.updated = current_timestamp; RETURN NEW; END;
    $body$ LANGUAGE plpgsql;

    DO $init$
    DECLARE t text;
    BEGIN
      FOREACH t IN ARRAY ARRAY['fanart','tadb','wikipedia','artist','album','spotify'] LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I (key varchar PRIMARY KEY, expires timestamptz, updated timestamptz DEFAULT current_timestamp, value bytea)', t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(expires)', t || '_expires_idx', t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(updated DESC) INCLUDE (key)', t || '_updated_idx', t);
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t || '_updated_trigger') THEN
          EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW WHEN (OLD.value IS DISTINCT FROM NEW.value) EXECUTE PROCEDURE cache_updated()', t || '_updated_trigger', t);
        END IF;
      END LOOP;
    END
    $init$;
  '';

  lmCacheInitStep = pkgs.writeShellScript "musicbrainz-lm-cache-init" ''
    set -euo pipefail
    # Wait up to 60s for postgres to be ready
    for i in $(seq 1 30); do
      ${pkgs.podman}/bin/podman exec musicbrainz-db-1 psql -U abc -c "SELECT 1" >/dev/null 2>&1 && break
      sleep 2
    done
    # Create lm_cache_db if not present
    db_exists=$(${pkgs.podman}/bin/podman exec musicbrainz-db-1 \
      psql -U abc -tAc "SELECT 1 FROM pg_database WHERE datname='lm_cache_db'" 2>/dev/null || true)
    if [ -z "$db_exists" ]; then
      ${pkgs.podman}/bin/podman exec musicbrainz-db-1 psql -U abc -c "CREATE DATABASE lm_cache_db"
    fi
    # Apply schema (fully idempotent)
    ${pkgs.podman}/bin/podman exec -i musicbrainz-db-1 \
      psql -U abc -d lm_cache_db < ${lmCacheInitSql}
  '';
in {
  options.homelab.services.musicbrainz = {
    enable = lib.mkEnableOption "MusicBrainz mirror with LMD and LRCLIB";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/musicbrainz";
      description = "Directory for backed-up app state (mqdata, lmdconfig).";
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

    lmdPort = lib.mkOption {
      type = lib.types.port;
      default = 5001;
      description = "Port for the LMD (Lidarr Metadata) service.";
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
      podman.containers = ["musicbrainz.service"];

      monitoring.monitors = [
        {
          name = "LMD (Lidarr Metadata)";
          url = "http://${localIp}:${toString cfg.lmdPort}/";
        }
        {
          name = "LRCLIB";
          url = "http://${localIp}:${toString cfg.lrclibPort}/api/search?artist_name=Radiohead&track_name=Creep";
        }
      ];
    };

    sops.secrets."musicbrainz/env" = {
      sopsFile = config.homelab.secrets.sopsFile "musicbrainz.env";
      format = "dotenv";
    };

    networking.firewall.allowedTCPPorts = [cfg.webPort cfg.lmdPort cfg.lrclibPort];

    systemd = {
      services = {
        musicbrainz = {
          description = "MusicBrainz Mirror + LMD + LRCLIB stack";
          after = ["network-online.target" "podman.service"];
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];

          environment = {
            MUSICBRAINZ_WEB_SERVER_PORT = toString cfg.webPort;
          };

          path = [pkgs.podman pkgs.docker-compose pkgs.coreutils pkgs.gnugrep];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "600s";
            RequiresMountsFor = [cfg.dataDir cfg.mirrorDir];
            ExecStop = "${composeScript} stop";
          };

          preStart = ''
            # Load Nix-built lrclib image into podman
            ${pkgs.podman}/bin/podman load --input ${lrclibImage}
            # Extract replication token from sops env file
            ${tokenExtractScript}
          '';

          script = ''
            ${composeScript} up -d --remove-orphans
          '';

          postStart = ''
            ${lmCacheInitStep}
          '';

          restartTriggers = [
            lrclibImage
            volumeOverride
            settingsOverride
            lmdOverride
            replicationTokenOverride
            lrclibImageOverride
          ];
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
      };

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
        "d ${cfg.dataDir}/lmdconfig 0755 root root - -"
        # Mirror data (large, re-downloadable, NOT backed up)
        "d ${cfg.mirrorDir} 0755 root root - -"
        "d ${cfg.mirrorDir}/pgdata 0755 root root - -"
        "d ${cfg.mirrorDir}/solrdata 0755 root root - -"
        "d ${cfg.mirrorDir}/dbdump 0755 root root - -"
        "d ${cfg.mirrorDir}/solrdump 0755 root root - -"
        "d ${cfg.mirrorDir}/lrclib 0755 root root - -"
      ];
    };
  };
}
