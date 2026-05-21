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
  # The space-bearing source paths are escaped per systemd.exec(5) (backslash-
  # space) and bound to space-free destinations inside the unit's sandboxed
  # /mnt tmpfs — see sandbox below. Upstream paperless's `mediaDir` /
  # `consumptionDir` then point at the space-free destinations directly, no
  # symlinks required.
  realMediaDir = ''/mnt/data/Life/Meg\ and\ Andy/Paperless/Documents'';
  realScansDir = ''/mnt/data/Life/Meg\ and\ Andy/Scans'';
  mediaDir = "/mnt/paperless-media";
  consumeDir = "/mnt/paperless-consume";

  # Per-unit sandbox: replace /mnt with an empty tmpfs and bind only the three
  # paths paperless actually needs. This narrows paperless's visible filesystem
  # to its own data (cf. anti-pattern: paperless used to see all of /mnt/data,
  # /mnt/appdata, /mnt/mum, /mnt/mirrors, /mnt/virtio — ro but every byte
  # readable). BindPaths fails loudly if a source isn't bindable
  # (status=226/NAMESPACE), so a missing/stale NFS path will surface as a
  # failed unit + the unit's existing errorPattern alert, not silent
  # read-only-fs at first write.
  mntSandbox = {
    serviceConfig = {
      TemporaryFileSystem = "/mnt";
      BindPaths = [
        "${realMediaDir}:${mediaDir}"
        "${realScansDir}:${consumeDir}"
        "${cfg.dataDir}"
      ];
    };
  };

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

    services.paperless = {
      enable = true;
      port = 28981;
      address = "0.0.0.0";
      inherit (cfg) dataDir;

      inherit mediaDir;
      consumptionDir = consumeDir;

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

    # All paperless services must wait for DB container and NFS, pick up the
    # pgpass env file so PAPERLESS_DBPASSWORD is set for libpq, and sandbox
    # /mnt to only the paths paperless legitimately needs.
    systemd.services = let
      base =
        dbAndNfs
        // {
          serviceConfig =
            mntSandbox.serviceConfig
            // {
              EnvironmentFile = lib.mkAfter [config.sops.secrets."paperless-pgpass".path];
            };
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
          name = "Paperless consumer NFS/auth failure";
          unit = "paperless-consumer.service";
          # NAMESPACE = BindPaths source unavailable (NFS stale, dir gone).
          # Excludes the chronic ConsumerError(duplicate) noise.
          pattern = "(?i)Failed at step NAMESPACE|password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "paperless-consumer cannot start or connect to DB";
          description = "Document ingest is stopped while NFS/DB is broken.";
        }
        {
          name = "Paperless scheduler NFS/degraded";
          unit = "paperless-scheduler.service";
          # NAMESPACE = BindPaths source unavailable.
          # Redis MISCONF = disk persistence broken; beat won't schedule.
          # DB auth = #232 class.
          pattern = "(?i)Failed at step NAMESPACE|password authentication failed for user \"paperless\"|celery\\.beat.*MISCONF";
          severity = "warning";
          summary = "celery beat scheduler is degraded";
        }
        {
          name = "Paperless task queue NFS/worker dead";
          unit = "paperless-task-queue.service";
          # NAMESPACE = BindPaths source unavailable.
          # Worker death = ingest pipeline stops. Excludes per-doc
          # ConsumerError + OCR ghostscript warnings.
          pattern = "(?i)Failed at step NAMESPACE|\\[CRITICAL\\] \\[celery\\.worker\\] Unrecoverable|password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "celery worker can't start or died — document ingest stopped";
        }
      ];
    };
  };
}
