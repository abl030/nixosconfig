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

  # Symlinks to NFS paths — avoids spaces in paths which break systemd ReadWritePaths
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

    # Symlinks from space-free paths to NFS dirs.
    # Upstream paperless module puts mediaDir/consumptionDir into systemd
    # ReadWritePaths= which splits on spaces — paths with spaces silently break.
    systemd.tmpfiles.rules = [
      "L+ ${mediaLink} - - - - /mnt/data/Life/Meg and Andy/Paperless/Documents"
      "L+ ${consumeLink} - - - - /mnt/data/Life/Meg and Andy/Paperless/Import"
    ];

    # Overlay the Scans folder onto Import/scans so recursive consume picks
    # up scanner output. Mirrors the original podman-compose two-mount layout.
    #
    # _netdev is REQUIRED — source path is under /mnt/data (NFS). Without it,
    # systemd-fstab-generator places this unit in local-fs.target, which is
    # ordered BEFORE network-online.target. The bind After= mnt-data.mount
    # After= network-online.target then closes a cycle through local-fs.target,
    # and systemd resolves it by deleting random start jobs (witnessed on
    # 2026-05-13: network-online.target/start was deleted, taking down gatus
    # and webdav on boot). _netdev moves the unit to remote-fs.target.
    # See docs/wiki/infrastructure/systemd-mount-ordering-cycles.md.
    fileSystems."/mnt/data/Life/Meg and Andy/Paperless/Import/scans" = {
      device = "/mnt/data/Life/Meg and Andy/Scans";
      fsType = "none";
      options = ["bind" "_netdev" "nofail" "x-systemd.requires=mnt-data.mount" "x-systemd.after=mnt-data.mount"];
    };

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
      base = dbAndNfs // {
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

    # Secrets
    sops.secrets."paperless/env" = {
      sopsFile = config.homelab.secrets.sopsFile "paperless.env";
      format = "dotenv";
      owner = "paperless";
      mode = "0400";
    };
    sops.secrets."paperless/password" = {
      sopsFile = config.homelab.secrets.sopsFile "paperless-admin-password";
      format = "binary";
      owner = "paperless";
      mode = "0400";
    };
    # PG password file — POSTGRES_PASSWORD + PAPERLESS_DBPASSWORD aliases of
    # the same value; see #232. mode 0444 because the nspawn container reads
    # via bindmount; the file contains nothing but the DB password.
    sops.secrets."paperless-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "paperless-pgpass.env";
      format = "dotenv";
      mode = "0444";
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
    };
  };
}
