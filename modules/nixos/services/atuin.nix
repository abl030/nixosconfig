{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.atuin;
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "atuin";
    hostNum = 1;
    inherit (cfg) dataDir;
  };
in {
  options.homelab.services.atuin = {
    enable = lib.mkEnableOption "Atuin shell history sync server";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/atuin-server";
      description = "Directory for Atuin server state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Self-contained PG instance in a NixOS container
    containers.atuin-db = pgc.containerConfig;

    services.atuin = {
      enable = true;
      port = 8888;
      host = "0.0.0.0";
      openRegistration = true;
      database = {
        createLocally = false;
        uri = pgc.dbUri;
      };
    };

    # Atuin must wait for its database container.
    # restartTriggers: see immich.nix comment — Requires= cascade-stops atuin
    # when the container restarts, but switch-to-configuration won't bring it
    # back unless its own unit file changed.
    systemd.services.atuin = {
      after = ["container@atuin-db.service"];
      requires = ["container@atuin-db.service"];
      restartTriggers = [config.systemd.units."container@atuin-db.service".unit];
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "atuin.ablz.au";
          port = 8888;
        }
      ];

      monitoring.monitors = [
        {
          name = "Atuin";
          url = "https://atuin.ablz.au/";
        }
      ];
    };
  };
}
