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

    # Static user instead of upstream DynamicUser — we need predictable UID
    # for file ownership on virtiofs (migrated data from compose has mismatched UIDs).
    users.users.mealie = {
      isSystemUser = true;
      group = "mealie";
      home = "/var/lib/mealie";
    };
    users.groups.mealie = {};

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
    # Override DynamicUser with static user for predictable file ownership,
    # and bind the virtiofs path onto /var/lib/mealie.
    systemd.services.mealie = {
      after = ["container@mealie-db.service"];
      requires = ["container@mealie-db.service"];
      serviceConfig =
        {
          DynamicUser = lib.mkForce false;
        }
        // lib.optionalAttrs (cfg.dataDir != "/var/lib/mealie") {
          BindPaths = ["${cfg.dataDir}:/var/lib/mealie"];
        };
    };

    sops.secrets."mealie/env" = {
      sopsFile = config.homelab.secrets.sopsFile "mealie.env";
      format = "dotenv";
      owner = "mealie";
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
  };
}
