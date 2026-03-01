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
  };

  # Symlinks to NFS paths — avoids spaces in paths which break systemd ReadWritePaths
  mediaLink = "/var/lib/paperless-media";
  consumeLink = "/var/lib/paperless-consume";

  # Shared deps for all paperless systemd services
  dbAndNfs = {
    after = ["container@paperless-db.service" "mnt-data.mount"];
    requires = ["container@paperless-db.service" "mnt-data.mount"];
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

    # All paperless services must wait for DB container and NFS
    systemd.services = {
      paperless-scheduler = dbAndNfs;
      paperless-task-queue = dbAndNfs;
      paperless-consumer = dbAndNfs;
      paperless-web = dbAndNfs;
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
