{
  config,
  inputs,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  # Operations and cutover guard: docs/wiki/services/musicbrainz.md
  cfg = config.homelab.services.musicbrainz;
  localIp = hostConfig.localIp or "127.0.0.1";
  pgpassSecret = config.sops.secrets."musicbrainz-pgpass".path;
  cratediggerGate = config.homelab.services.cratedigger.metadataGate;
  cratediggerGateEnabled = config.homelab.services.cratedigger.enable;

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
      Volumes = {"/data" = {};};
    };
  };

  # --- Compose files ---
  baseCompose = "${inputs.musicbrainz-docker}/docker-compose.yml";
  dbShimImage = pkgs.dockerTools.buildLayeredImage {
    name = "musicbrainz-db-disabled";
    tag = "latest";
    contents = [pkgs.busybox];
    config.Cmd = ["/bin/sleep" "infinity"];
  };

  # All named volume bind mounts — mirrors vs backed-up split. PostgreSQL is
  # intentionally absent here; the compose-owned DB was retired in favor of the
  # nspawn database below. Legacy pghome/pgdata directories are retained only as
  # rollback state until the external DB cutover is verified.
  volumeOverride = pkgs.writeText "musicbrainz-volumes.yml" ''
    volumes:
      mqdata:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.dataDir}/mqdata
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
      lrclib-data:
        driver: local
        driver_opts:
          type: none
          device: ${cfg.mirrorDir}/lrclib
          o: bind
  '';

  # Solr heap and MB web server host. DB credentials and host live in
  # externalDbOverride so they can consume the narrow pgpass env file.
  settingsOverride = pkgs.writeText "musicbrainz-settings.yml" ''
    services:
      musicbrainz:
        environment:
          MUSICBRAINZ_WEB_SERVER_HOST: "${localIp}"
      search:
        mem_swappiness: -1
        environment:
          - SOLR_HEAP=2g
  '';

  # Replace upstream's compose-owned PostgreSQL service with an inert
  # compatibility container, and point MusicBrainz/indexer at the fleet-managed
  # nspawn database. The reset/override tags are verified with docker-compose
  # config in the validation flow.
  externalDbOverride = pkgs.writeText "musicbrainz-external-db.yml" ''
    services:
      db:
        image: musicbrainz-db-disabled:latest
        build: !reset null
        command: ["/bin/sleep", "infinity"]
        env_file: !reset []
        pull_policy: never
        shm_size: !reset null
        volumes: !reset []
        expose: !reset []

      # The external nspawn DB must publish SIR trigger events into RabbitMQ.
      # Bind only on the host side of the nspawn veth, not on a LAN address.
      mq:
        ports:
          - "${pgc.hostAddress}:5672:5672"

      musicbrainz:
        depends_on: !override
          - mq
          - search
          - valkey
        environment:
          POSTGRES_USER: "musicbrainz"
          POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}"
          MUSICBRAINZ_POSTGRES_SERVER: "${pgc.dbHost}"
          MUSICBRAINZ_POSTGRES_READONLY_SERVER: "${pgc.dbHost}"
          MUSICBRAINZ_REDIS_SERVER: "valkey"
          MUSICBRAINZ_VALKEY_SERVER: "valkey"

      indexer:
        depends_on: !override
          - mq
          - search
        environment:
          POSTGRES_USER: "musicbrainz"
          POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}"
          MUSICBRAINZ_POSTGRES_SERVER: "${pgc.dbHost}"
          MUSICBRAINZ_POSTGRES_READONLY_SERVER: "${pgc.dbHost}"
  '';

  # LRCLIB service definition for local Beets lyrics lookup.
  lrclibOverride = pkgs.writeText "musicbrainz-lrclib.yml" ''
    services:
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
    externalDbOverride
    lrclibOverride
    replicationTokenOverride
    lrclibImageOverride
  ];
  composeFlags = lib.concatMapStringsSep " " (f: "-f ${f}") composeFiles;

  composeScript = pkgs.writeShellScript "musicbrainz-compose" ''
    exec ${pkgs.podman}/bin/podman compose \
      --project-name musicbrainz \
      ${composeFlags} \
      --env-file ${envFile} \
      --env-file ${pgpassSecret} \
      "$@"
  '';

  cutoverApprovalPath = "/var/lib/musicbrainz-cutover/external-db-approved.json";
  cutoverGuard = pkgs.writeShellScript "musicbrainz-external-db-cutover-guard" ''
    set -euo pipefail

    if [ ! -s ${cutoverApprovalPath} ]; then
      echo "ERROR: ${cutoverApprovalPath} is required before starting MusicBrainz against the external PostgreSQL boundary." >&2
      echo "Record the migration/rebuild path, source state, rollback ref, old data paths, and ${cfg.mirrorDir}/postgres-nspawn in that JSON file." >&2
      exit 1
    fi

    ${pkgs.jq}/bin/jq -e '
      (.path == "dump-restore" or .path == "rebuild-import") and
      .sourceState and
      (.rollbackRef | type == "string" and length > 0) and
      (.oldDataPaths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
      .newDataPath == "${cfg.mirrorDir}/postgres-nspawn/postgres"
    ' ${cutoverApprovalPath} >/dev/null

    ${pkgs.jq}/bin/jq -r '.oldDataPaths[]' ${cutoverApprovalPath} | while IFS= read -r path; do
      if [ ! -e "$path" ]; then
        echo "ERROR: oldDataPaths entry does not exist: $path" >&2
        exit 1
      fi
    done

    if [ ! -d "${cfg.mirrorDir}/postgres-nspawn/postgres" ]; then
      echo "ERROR: expected new MusicBrainz DB path is missing: ${cfg.mirrorDir}/postgres-nspawn/postgres" >&2
      exit 1
    fi
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
    ${composeScript} exec -T indexer python -m sir amqp_setup

    if [ "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'amqp')")" != "t" ]; then
      ${composeScript} exec -T indexer sh -c 'MUSICBRAINZ_RABBITMQ_SERVER=${pgc.hostAddress} python -m sir extension'
      indexer_id="$(${composeScript} ps -q indexer)"
      ${pkgs.podman}/bin/podman cp "$indexer_id:/code/sql/CreateExtension.sql" "$tmp/CreateExtension.sql"
      psql_file "$tmp/CreateExtension.sql"
    fi

    psql_exec "INSERT INTO amqp.broker (host, port) SELECT '${pgc.hostAddress}', 5672 WHERE NOT EXISTS (SELECT 1 FROM amqp.broker)"
    psql_exec "UPDATE amqp.broker SET host = '${pgc.hostAddress}', port = 5672"
    if [ "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM amqp.broker WHERE host = '${pgc.hostAddress}' AND port = 5672)")" != "t" ]; then
      echo "ERROR: MusicBrainz AMQP broker was not configured for ${pgc.hostAddress}:5672" >&2
      exit 1
    fi

    if [ "$(psql_scalar "SELECT count(*) > 0 FROM pg_trigger WHERE NOT tgisinternal")" != "t" ]; then
      ${composeScript} exec -T indexer python -m sir triggers
      ${composeScript} exec -T indexer ./GenerateDropSql.pl
      indexer_id="$(${composeScript} ps -q indexer)"
      musicbrainz_id="$(${composeScript} ps -q musicbrainz)"
      ${pkgs.podman}/bin/podman cp "$indexer_id:/code/sql" "$tmp/indexer-sql"
      ${pkgs.podman}/bin/podman cp "$tmp/indexer-sql" "$musicbrainz_id:/tmp/indexer-sql"
      ${composeScript} exec -T musicbrainz indexer-triggers.sh /tmp/indexer-sql create
      ${composeScript} exec -T musicbrainz rm -rf /tmp/indexer-sql
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
          -H 'User-Agent: musicbrainz-cutover-verify/1.0 (local homelab)' \
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
    mkdir -p /run/secrets
    token=$(grep '^REPLICATION_ACCESS_TOKEN=' ${envFile} | cut -d= -f2-)
    if [ -z "$token" ]; then
      echo "ERROR: REPLICATION_ACCESS_TOKEN not found in ${envFile}" >&2
      exit 1
    fi
    printf '%s' "$token" > ${mbTokenPath}
    chmod 600 ${mbTokenPath}
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
        {unit = "musicbrainz.service";}
      ];

      monitoring.monitors = [
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

    sops.secrets."musicbrainz-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "musicbrainz-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    containers.musicbrainz-db = pgc.containerConfig;

    networking.firewall.allowedTCPPorts = [cfg.webPort cfg.lrclibPort];

    systemd = {
      services = {
        musicbrainz = {
          description = "MusicBrainz Mirror + LRCLIB stack";
          after = ["network-online.target" "podman.service" "container@musicbrainz-db.service"];
          wants = ["network-online.target"];
          requires = ["container@musicbrainz-db.service"];
          wantedBy = ["multi-user.target"];
          # DB cutover is migration-sensitive. Rebuilds should not silently stop
          # the old compose DB and start the external-DB path before the approval
          # marker exists. The DB container postStart below recovers this unit
          # after approved cutover if a container restart cascade-stops it.
          restartIfChanged = false;
          unitConfig.RequiresMountsFor = [cfg.dataDir cfg.mirrorDir];

          environment = {
            MUSICBRAINZ_WEB_SERVER_PORT = toString cfg.webPort;
          };

          path = [pkgs.podman pkgs.docker-compose pkgs.coreutils pkgs.gnugrep];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "600s";
            StateDirectory = "musicbrainz-cutover";
            ExecStop = "${composeScript} stop";
          };

          preStart = ''
            ${cutoverGuard}
            ${dbPreflightVerifyScript}
            ${lib.optionalString cratediggerGateEnabled ''
              ${cratediggerGate.holdCommand} musicbrainz-maintenance
              release_gate_on_error() {
                ${cratediggerGate.releaseCommand} musicbrainz-maintenance || true
              }
              trap release_gate_on_error ERR
            ''}
            # Load Nix-built lrclib image into podman
            ${pkgs.podman}/bin/podman load --input ${lrclibImage}
            # Load Nix-built inert db shim so compose never pulls a mutable DB image
            ${pkgs.podman}/bin/podman load --input ${dbShimImage}
            # Extract replication token from sops env file
            ${tokenExtractScript}
            ${lib.optionalString cratediggerGateEnabled ''
              trap - ERR
            ''}
          '';

          script = ''
            ${composeScript} up -d --remove-orphans
          '';

          restartTriggers = [
            lrclibImage
            volumeOverride
            settingsOverride
            externalDbOverride
            lrclibOverride
            dbShimImage
            dbPreflightVerifyScript
            dbVerifyScript
            amqpSetupScript
            apiVerifyScript
            replicationTokenOverride
            lrclibImageOverride
            pgpassSecret
            cutoverGuard
            config.systemd.units."container@musicbrainz-db.service".unit
          ];

          postStart = ''
            ${amqpSetupScript}
            ${apiVerifyScript}
            ${dbVerifyScript}
            ${lib.optionalString cratediggerGateEnabled ''
              ${cratediggerGate.releaseCommand} musicbrainz-maintenance
              ${cratediggerGate.resumeIfClearCommand} || true
            ''}
          '';
        };

        "container@musicbrainz-db" = {
          postStart = ''
            if [ -s ${cutoverApprovalPath} ]; then
              ${pkgs.systemd}/bin/systemctl --no-block start musicbrainz.service
            fi
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
        # Mirror data (large, re-downloadable, NOT backed up)
        "d ${cfg.mirrorDir} 0755 root root - -"
        "d ${cfg.mirrorDir}/pgdata 0755 root root - -"
        "d ${cfg.mirrorDir}/pghome 0755 root root - -"
        "d ${cfg.mirrorDir}/postgres-nspawn 0755 root root - -"
        "d ${cfg.mirrorDir}/postgres-nspawn/postgres 0700 root root - -"
        "d ${cfg.mirrorDir}/solrdata 0755 root root - -"
        "d ${cfg.mirrorDir}/dbdump 0755 root root - -"
        "d ${cfg.mirrorDir}/solrdump 0755 root root - -"
        "d ${cfg.mirrorDir}/lrclib 0755 root root - -"
      ];
    };
  };
}
