{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.mealie;
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "mealie";
    hostNum = 4;
    pgPackage = pkgs.postgresql_15;
    inherit (cfg) dataDir;
  };
in {
  options.homelab.services.mealie = {
    enable = lib.mkEnableOption "Mealie recipe manager";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mealie";
      description = "Directory for Mealie app state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.mealie-db = pgc.containerConfig;

    # Upstream hardcodes DATA_DIR=/var/lib/mealie and StateDirectory=mealie.
    # Use BindPaths to map virtiofs onto /var/lib/mealie so DynamicUser + StateDirectory
    # still works (systemd manages ownership via the StateDirectory mechanism).

    services.mealie = {
      enable = true;
      port = 9925;
      listenAddress = "0.0.0.0";
      credentialsFile = config.sops.secrets."mealie/env".path;
      database.createLocally = false;
      settings = {
        ALLOW_SIGNUP = "false";
        ALLOW_GUEST_ACCESS = "true";
        DEFAULT_GROUP = "home";
        TZ = "Australia/Perth";
        BASE_URL = "https://cooking.ablz.au";
        DB_ENGINE = "postgres";
        POSTGRES_USER = "mealie";
        POSTGRES_SERVER = pgc.dbHost;
        POSTGRES_PORT = toString pgc.dbPort;
        POSTGRES_DB = "mealie";
      };
    };

    # Mealie service must wait for DB container.
    # BindPaths maps the custom dataDir onto /var/lib/mealie so the upstream
    # StateDirectory=mealie still works (systemd chowns it to the DynamicUser).
    systemd.services.mealie = {
      after = ["container@mealie-db.service"];
      requires = ["container@mealie-db.service"];
      serviceConfig = lib.mkIf (cfg.dataDir != "/var/lib/mealie") {
        BindPaths = ["${cfg.dataDir}:/var/lib/mealie"];
      };
    };

    # DynamicUser — systemd reads EnvironmentFile as root before dropping privs
    sops.secrets."mealie/env" = {
      sopsFile = config.homelab.secrets.sopsFile "mealie.env";
      format = "dotenv";
      mode = "0400";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "cooking.ablz.au";
          port = 9925;
        }
      ];
      monitoring.monitors = [
        {
          name = "Mealie";
          url = "https://cooking.ablz.au/api/app/about";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [9925];
  };
}
