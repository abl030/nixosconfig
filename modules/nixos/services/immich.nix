{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.immich;

  # Extension-creation SQL — replicated from upstream's unguarded ExecStartPost
  # (nixpkgs #388806). We run this inside the container instead.
  immichExtensionSQL = ''
    CREATE EXTENSION IF NOT EXISTS "unaccent";
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "cube";
    CREATE EXTENSION IF NOT EXISTS "earthdistance";
    CREATE EXTENSION IF NOT EXISTS "pg_trgm";
    CREATE EXTENSION IF NOT EXISTS "vectors";
    CREATE EXTENSION IF NOT EXISTS "vector";
    CREATE EXTENSION IF NOT EXISTS "vchord";
    ALTER EXTENSION "unaccent" UPDATE;
    ALTER EXTENSION "uuid-ossp" UPDATE;
    ALTER EXTENSION "cube" UPDATE;
    ALTER EXTENSION "earthdistance" UPDATE;
    ALTER EXTENSION "pg_trgm" UPDATE;
    ALTER EXTENSION "vectors" UPDATE;
    ALTER EXTENSION "vector" UPDATE;
    ALTER EXTENSION "vchord" UPDATE;
    ALTER SCHEMA public OWNER TO immich;
    ALTER SCHEMA vectors OWNER TO immich;
    GRANT SELECT ON TABLE pg_vector_index_stat TO immich;
  '';

  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "immich";
    hostNum = 2;
    inherit (cfg) dataDir;
    extensions = ps: [ps.pgvecto-rs ps.pgvector ps.vectorchord];
    pgSettings = {
      shared_preload_libraries = ["vectors.so" "vchord.so"];
      search_path = ''"$user", public, vectors'';
    };
    postStartSQL = immichExtensionSQL;
  };
in {
  options.homelab.services.immich = {
    enable = lib.mkEnableOption "Immich photo management";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/immich-server";
      description = "Directory for Immich server state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Self-contained PG instance in a NixOS container
    containers.immich-db = pgc.containerConfig;

    services.immich = {
      enable = true;
      port = 2283;
      host = "0.0.0.0";
      mediaLocation = "/mnt/data/Life/Photos";

      database = {
        enable = false;
        enableVectorChord = true;
        enableVectors = true;
        host = pgc.dbHost;
        port = pgc.dbPort;
        name = "immich";
        user = "immich";
      };

      redis.enable = true;
      machine-learning.enable = true;

      secretsFile = config.sops.secrets."immich/env".path;

      environment = {
        IMMICH_TELEMETRY_INCLUDE = "all";
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://192.168.1.33:4317";
        OTEL_TRACES_EXPORTER = "otlp";
        OTEL_SERVICE_NAME = "immich";
        IMMICH_METRICS = "true";
        IMMICH_METRICS_PORT = "8081";
      };
    };

    # Neutralize upstream's unguarded ExecStartPost (nixpkgs #388806)
    systemd.services.postgresql-setup.serviceConfig.ExecStartPost = lib.mkForce [];

    # Immich must wait for its database container
    systemd.services.immich-server = {
      after = ["container@immich-db.service"];
      requires = ["container@immich-db.service"];
    };

    # Sops secret for Immich env (DB_PASSWORD required for TCP connections)
    sops.secrets."immich/env" = {
      sopsFile = config.homelab.secrets.sopsFile "immich.env";
      format = "dotenv";
      owner = "immich";
      group = "immich";
      mode = "0400";
    };

    # Wire into existing infrastructure
    homelab = {
      localProxy.hosts = [
        {
          host = "photos.ablz.au";
          port = 2283;
          websocket = true;
          maxBodySize = "0";
        }
      ];

      monitoring.monitors = [
        {
          name = "Immich";
          url = "https://photos.ablz.au/api/server/ping";
        }
      ];

      loki.extraScrapeTargets = [
        {
          job = "immich";
          address = "localhost:8081";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [8081];
  };
}
