{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.paperless;
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "paperless";
    hostNum = 3;
    inherit (cfg) dataDir;
    passwordFile = "/run/secrets/paperless-pgpass";
  };

  # Real Paperless storage paths live on tower NFS under a path with spaces.
  # Expose space-free symlinks to Paperless because the upstream module wires
  # these into systemd ReadWritePaths=, where literal spaces are fragile.
  mediaDir = "/mnt/data/Life/Meg and Andy/Paperless/Documents";
  scanDir = "/mnt/data/Life/Meg and Andy/Scans";
  mediaLink = "/var/lib/paperless-media";
  consumeLink = "/var/lib/paperless-consume";

  # Shared deps for all paperless systemd services.
  # restartTriggers: see immich.nix comment — Requires= cascade-stops paperless
  # services when the container restarts, but switch-to-configuration won't bring
  # them back unless their own unit files changed.
  dbAndNfs = {
    after = ["container@paperless-db.service" "mnt-data.mount"];
    requires = ["container@paperless-db.service" "mnt-data.mount"];
    restartTriggers = [config.systemd.units."container@paperless-db.service".unit];
  };
in {
  options.homelab.services.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx document management";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/paperless";
      description = "Directory for Paperless app state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL in nspawn container (pattern: immich, atuin)
    containers.paperless-db = pgc.containerConfig;

    # Paperless consumes scanner output directly. The older docker-era layout
    # consumed Paperless/Import with Scans bind-mounted underneath it, but that
    # introduced a space-bearing fstab mountpoint. switch-to-configuration-ng
    # double-escapes fstab's \040 spaces when deciding which mount unit to
    # reload, so keep the runtime path space-free instead.
    # See docs/wiki/infrastructure/systemd-mount-ordering-cycles.md.
    systemd.tmpfiles.rules = [
      "L+ ${mediaLink} - - - - ${mediaDir}"
      "L+ ${consumeLink} - - - - ${scanDir}"
    ];

    services.paperless = {
      enable = true;
      port = 28981;
      address = "0.0.0.0";
      inherit (cfg) dataDir;

      mediaDir = mediaLink;
      consumptionDir = consumeLink;

      # Tika + Gotenberg for OCR of Office docs and emails
      configureTika = true;

      # External postgres via nspawn container
      database.createLocally = false;

      # Admin password — only used on first run to create superuser
      passwordFile = config.sops.secrets."paperless/password".path;

      # DB password and other secrets via environment file
      environmentFile = config.sops.secrets."paperless/env".path;

      settings = {
        PAPERLESS_DBENGINE = "postgresql";
        PAPERLESS_DBHOST = pgc.dbHost;
        PAPERLESS_DBPORT = pgc.dbPort;
        PAPERLESS_DBNAME = "paperless";
        PAPERLESS_DBUSER = "paperless";
        PAPERLESS_URL = "https://paperless.ablz.au";
        PAPERLESS_CONSUMER_RECURSIVE = true;
        PAPERLESS_CONSUMER_POLLING = 60;
        PAPERLESS_TIME_ZONE = "Australia/Perth";
      };
    };

    # All paperless services must wait for DB container and NFS, plus pick up
    # the pgpass env file so PAPERLESS_DBPASSWORD is set for libpq.
    systemd.services = let
      base =
        dbAndNfs
        // {
          serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."paperless-pgpass".path];
        };
    in {
      paperless-scheduler = base;
      paperless-task-queue = base;
      paperless-consumer = base;
      paperless-web = base;
    };

    # Paperless user needs NFS access
    users.users.paperless.extraGroups = ["users"];

    sops.secrets = {
      # Secrets
      "paperless/env" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless.env";
        format = "dotenv";
        owner = "paperless";
        mode = "0400";
      };
      "paperless/password" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless-admin-password";
        format = "binary";
        owner = "paperless";
        mode = "0400";
      };
      # PG password file — POSTGRES_PASSWORD + PAPERLESS_DBPASSWORD aliases of
      # the same value; the file contains nothing but the DB password.
      "paperless-pgpass" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless-pgpass.env";
        format = "dotenv";
        mode = "0400";
      };
    };

    homelab = {
      nfsWatchdog.paperless-web.path = "/mnt/data";

      localProxy.hosts = [
        {
          host = "paperless.ablz.au";
          port = 28981;
        }
      ];

      monitoring.monitors = [
        {
          name = "Paperless";
          url = "https://paperless.ablz.au/";
        }
      ];

      # See #253 audit + rules-doc "Per-service errorPatterns".
      monitoring.errorPatterns = [
        {
          name = "Paperless web NFS/auth failure";
          unit = "paperless-web.service";
          # NAMESPACE failure = NFS+BindPaths cycle.
          # pgauth failure = DB grant regression (#232 trust→scram).
          pattern = "(?i)Failed at step NAMESPACE|password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "paperless-web cannot start or connect to DB";
          description = ''
            NAMESPACE failures are an NFS/mount issue — check
            mnt-data-*.mount on doc2 and the nfs-watchdog. pgauth
            failures match the #232 trust→scram class.
          '';
        }
        {
          name = "Paperless consumer DB auth";
          unit = "paperless-consumer.service";
          # Excludes the chronic ConsumerError(duplicate) noise from
          # the per-file retry loop on stuck imports.
          pattern = "(?i)password authentication failed for user \"paperless\"";
          severity = "warning";
          summary = "paperless-consumer cannot connect to DB";
          description = "Document ingest is stopped while DB auth is broken.";
        }
        {
          name = "Paperless scheduler degraded";
          unit = "paperless-scheduler.service";
          # Redis MISCONF = disk persistence is broken; celery.beat
          # then refuses to schedule. DB auth = #232 class.
          pattern = "(?i)password authentication failed for user \"paperless\"|celery\\.beat.*MISCONF";
          severity = "warning";
          summary = "celery beat scheduler is degraded";
        }
        {
          name = "Paperless task queue worker dead";
          unit = "paperless-task-queue.service";
          # Worker death = ingest pipeline stops entirely. Excludes
          # per-doc ConsumerError + OCR ghostscript warnings.
          pattern = "(?i)\\[CRITICAL\\] \\[celery\\.worker\\] Unrecoverable|password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "celery worker died — document ingest stopped";
        }
      ];
    };
  };
}
