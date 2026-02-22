{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  stackName = "musicbrainz-stack";
  projectName = "musicbrainz";

  # Base compose from flake input — build contexts resolve relative to this path
  baseCompose = "${inputs.musicbrainz-docker}/docker-compose.yml";

  # lrclib — no public image, build via Nix to avoid crates.io CDN timeouts at deploy time
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

  # Compose override: reference the pre-loaded Nix image
  lrclibImageOverride = pkgs.writeText "musicbrainz-lrclib-image.yml" ''
    services:
      lrclib:
        image: lrclib-nix:latest
  '';

  # Override files from our repo — isolated via builtins.path for stable store paths
  postgresOverride = builtins.path {
    path = ./overrides/postgres-settings.yml;
    name = "musicbrainz-postgres-settings.yml";
  };
  memoryOverride = builtins.path {
    path = ./overrides/memory-settings.yml;
    name = "musicbrainz-memory-settings.yml";
  };
  volumeOverride = builtins.path {
    path = ./overrides/volume-settings.yml;
    name = "musicbrainz-volume-settings.yml";
  };
  lmdOverride = builtins.path {
    path = ./overrides/lmd-settings.yml;
    name = "musicbrainz-lmd-settings.yml";
  };
  replicationTokenOverride = builtins.path {
    path = ./overrides/replication-token.yml;
    name = "musicbrainz-replication-token.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "musicbrainz.env";

  # Replication token as a standalone sops secret (file format for container mount)
  replicationTokenSecretName = "musicbrainz-replication-token";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};

  volumeBase = "/mnt/docker/musicbrainz/volumes";

  # Load Nix-built lrclib image into rootless podman before compose starts
  buildStep = [
    "${pkgs.podman}/bin/podman load --input ${lrclibImage}"
  ];

  # LMD cache DB schema — idempotent, piped into the MB postgres instance post-start
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

  lmCacheInitStep = pkgs.writeShellScript "lm-cache-db-init" ''
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
  # Replication token: extracted as a standalone file for container bind-mount
  sops.secrets.${replicationTokenSecretName} = {
    sopsFile = encEnv;
    format = "dotenv";
    key = "REPLICATION_ACCESS_TOKEN";
    owner = config.homelab.user;
    mode = "0440";
  };

  systemd.tmpfiles.rules = [
    "d ${volumeBase}/mqdata    0755 abl030 users -"
    "d ${volumeBase}/pgdata    0755 abl030 users -"
    "d ${volumeBase}/solrdata  0755 abl030 users -"
    "d ${volumeBase}/dbdump    0755 abl030 users -"
    "d ${volumeBase}/solrdump  0755 abl030 users -"
    "d ${volumeBase}/lmdconfig 0755 abl030 users -"
    "d ${volumeBase}/lrclib    0755 abl030 users -"
  ];

  imports = [
    (podman.mkService {
      inherit stackName;
      description = "MusicBrainz Mirror + LMD Stack";
      inherit projectName;
      composeFile = baseCompose;
      extraComposeFiles = [postgresOverride memoryOverride volumeOverride lmdOverride lrclibImageOverride replicationTokenOverride];
      restartTriggers = ["${lrclibImage}"];
      composeArgs = "--project-name ${projectName}";
      envFiles = [
        {
          sopsFile = encEnv;
          runFile = "/run/user/%U/secrets/${stackName}.env";
        }
      ];
      preStart = buildStep;
      postStart = ["${lmCacheInitStep}"];
      extraEnv = ["MUSICBRAINZ_WEB_SERVER_PORT=5200"];
      firewallPorts = [5200 5001 3300];
      stackMonitors = [
        {
          name = "LMD (Lidarr Metadata)";
          url = "http://192.168.1.29:5001/";
        }
        {
          name = "LRCLIB";
          url = "http://192.168.1.29:3300/";
        }
      ];
      startupTimeoutSeconds = 600;
      after = ["network-online.target"];
      wants = ["network-online.target"];
    })
  ];

  home-manager.users.abl030.systemd.user = {
    services.musicbrainz-reindex = {
      Unit.Description = "MusicBrainz weekly Solr reindex";
      Service = {
        Type = "oneshot";
        Environment = [
          "XDG_RUNTIME_DIR=/run/user/1000"
          "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock"
        ];
        ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 python -m sir reindex --entity-type artist --entity-type release";
      };
    };
    timers.musicbrainz-reindex = {
      Unit.Description = "MusicBrainz weekly Solr reindex timer";
      Timer = {
        OnCalendar = "Sun 01:00";
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
