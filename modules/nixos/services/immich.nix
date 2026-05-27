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
    CREATE EXTENSION IF NOT EXISTS "vector";
    CREATE EXTENSION IF NOT EXISTS "vchord";
    ALTER EXTENSION "unaccent" UPDATE;
    ALTER EXTENSION "uuid-ossp" UPDATE;
    ALTER EXTENSION "cube" UPDATE;
    ALTER EXTENSION "earthdistance" UPDATE;
    ALTER EXTENSION "pg_trgm" UPDATE;
    ALTER EXTENSION "vector" UPDATE;
    ALTER EXTENSION "vchord" UPDATE;
    ALTER SCHEMA public OWNER TO immich;
    REINDEX INDEX IF EXISTS face_index;
    REINDEX INDEX IF EXISTS clip_index;
    -- Geocoder tables (geodata_places, naturalearth_countries) are loaded
    -- by Immich's microservices AS THE postgres superuser via COPY, so
    -- they end up postgres-owned with no grants for the immich role.
    -- The app then 'permission denied for table geodata_places' on
    -- reverse-geocode lookups during AssetExtractMetadata. Fixed
    -- declaratively: any future postgres-created table in `public`
    -- auto-grants SELECT to immich, and we retroactively grant on the
    -- geocoder tables if they already exist (idempotent).
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
      GRANT SELECT ON TABLES TO immich;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
      GRANT SELECT ON SEQUENCES TO immich;
    DO $immich_grants$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
                  WHERE n.nspname = 'public' AND c.relname = 'geodata_places') THEN
        EXECUTE 'GRANT SELECT ON TABLE public.geodata_places TO immich';
      END IF;
      IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
                  WHERE n.nspname = 'public' AND c.relname = 'naturalearth_countries') THEN
        EXECUTE 'GRANT SELECT ON TABLE public.naturalearth_countries TO immich';
      END IF;
      IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
                  WHERE n.nspname = 'public' AND c.relname = 'naturalearth_countries_tmp_id_seq1') THEN
        EXECUTE 'GRANT SELECT ON SEQUENCE public.naturalearth_countries_tmp_id_seq1 TO immich';
      END IF;
    END $immich_grants$;
  '';

  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "immich";
    hostNum = 2;
    inherit (cfg) dataDir;
    extensions = ps: [ps.pgvector ps.vectorchord];
    pgSettings = {
      shared_preload_libraries = ["vchord.so"];
      search_path = ''"$user", public'';
    };
    postStartSQL = immichExtensionSQL;
    passwordFile = "/run/secrets/immich-pgpass";
    # Schema-ownership allow-list. The invariant in mk-pg-container.nix
    # asserts every public.* table/view/sequence/index is owned by `immich`;
    # these are the legitimate exceptions owned by the postgres superuser
    # because they're loaded/created by the extension or geocoder import
    # rather than by app migrations.
    # See docs/wiki/services/immich-asset-edit-audit-incident.md and #250.
    ownershipAllowList = [
      # Reverse-geocoder data tables (loaded via COPY as superuser)
      "geodata_places"
      "naturalearth_countries"
      "naturalearth_countries_tmp_id_seq1"
      "geodata_places_pkey"
      "idx_geodata_places_admin1_name"
      "idx_geodata_places_admin2_name"
      "idx_geodata_places_alternate_names"
      "idx_geodata_places_name"
      "IDX_geodata_gist_earthcoord"
      "naturalearth_countries_pkey"
      # vectorchord (vchord) extension materialized helper
      "vchordrq_sampled_queries"
    ];
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

    # Neutralize upstream's unguarded postgresql-setup service (nixpkgs #388806).
    # With database.enable = false, no host PG creates this service, but upstream's
    # unguarded ExecStartPost still defines it — resulting in a stub with no ExecStart.
    # Wipe it completely so systemd doesn't reject the bad unit file.
    systemd.services = {
      postgresql-setup = lib.mkForce {};

      # Immich must wait for its database container.
      # restartTriggers: switch-to-configuration only restarts services whose unit
      # files changed.  When the container is restarted (its config changed),
      # Requires= cascade-stops immich-server, but nobody brings it back because
      # immich-server's own unit file may not have changed.  Pinning the trigger
      # to the container's host-side unit derivation (`systemd.units.<name>.unit`,
      # which captures the ExecStart/ExecReload wrapper scripts) ensures
      # switch-to-configuration always explicitly restarts immich-server whenever
      # the DB container's unit wrapper changes.
      #
      # DO NOT pin `config.containers.immich-db.config.system.build.toplevel`
      # here — that's the INNER NixOS system, not the outer unit wrapper.  The
      # wrapper is rebuilt by nixpkgs independently (unit-script-container_*-start),
      # which restarts the container while leaving the inner toplevel unchanged —
      # a silent cascade-stop orphaning trap.  See PR description for the 2026-04-13
      # incident that surfaced this.
      immich-server = {
        after = ["container@immich-db.service"];
        requires = ["container@immich-db.service"];
        restartTriggers = [config.systemd.units."container@immich-db.service".unit];
        # Inject pgpass into immich-server's EnvironmentFile after immich/env
        # (which `secretsFile` populates). Later entries win in systemd.
        serviceConfig.EnvironmentFile =
          lib.mkAfter [config.sops.secrets."immich-pgpass".path];
      };
    };

    # Sops secret for Immich env (DB_PASSWORD required for TCP connections)
    sops.secrets."immich/env" = {
      sopsFile = config.homelab.secrets.sopsFile "immich.env";
      format = "dotenv";
      owner = "immich";
      group = "immich";
      mode = "0400";
    };
    # PG password — POSTGRES_PASSWORD + DB_PASSWORD aliases of the same value.
    # Loaded after immich/env so the canonical value wins on duplicate keys.
    sops.secrets."immich-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "immich-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    # Wire into existing infrastructure
    homelab = {
      nfsWatchdog.immich-server.path = config.services.immich.mediaLocation;

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

      # Service-broken log signatures. See #253 audit + rules-doc
      # "Per-service errorPatterns".
      monitoring.errorPatterns = [
        {
          name = "Immich DB write failure";
          unit = "immich-server.service";
          # Catches the #250 asset_edit_audit class (permission denied
          # for table) plus any pg_dump backup failure. Skips noisy
          # ERR_HTTP_HEADERS_SENT and "Failed to fetch latest release"
          # — those are warns, not service-broken.
          pattern = "(?i)permission denied for table|pg_dump non-zero exit code|Database Backup Failure";
          severity = "critical";
          summary = "Immich app is throwing DB errors — uploads likely broken";
          description = ''
            The #250 signature. Cross-reference the schema-ownership
            invariant in mk-pg-container.nix + the asset_edit_audit
            incident wiki.
          '';
          # `pg_dump non-zero exit code` / `Database Backup Failure`
          # are single-shot terminal errors from the backup hook.
          # `permission denied for table` is the #250 class — at the
          # time of incident this was emitted on most user actions, so
          # would easily hit the default sustained threshold too, but
          # we want #250-class drift to page on the very first hit.
          threshold = 0;
        }
      ];

      # Deep write-path probe — catches the #250 asset_edit_audit class
      # of failure (DB permission drift that the shallow
      # /api/server/ping is blind to). Probes asset_edit_audit directly
      # as the immich role over TCP, since Immich's /api/sync/* endpoints
      # explicitly reject API-key auth ("Sync endpoints cannot be used
      # with API keys"). See probes/check-immich-sync.nix for the why.
      monitoring.deepProbes = [
        {
          name = "Immich sync write-path";
          command = "${pkgs.callPackage ./probes/check-immich-sync.nix {}}/bin/check-immich-sync";
          interval = "15m";
          intervalSecs = 900;
          serviceConfig = {
            Environment = [
              "IMMICH_PG_PASSWORD_FILE=${config.sops.secrets."immich-pgpass".path}"
              "IMMICH_PG_HOST=${pgc.dbHost}"
              "IMMICH_PG_PORT=${toString pgc.dbPort}"
            ];
          };
        }
      ];

      loki.extraScrapeTargets = [
        {
          job = "immich";
          address = "localhost:8081";
        }
      ];
    };

    # Port 8081 (metrics) open for remote Prometheus/Loki scraping from igpu
    networking.firewall.allowedTCPPorts = [8081];
  };
}
