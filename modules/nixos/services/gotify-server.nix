{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.gotify;
in {
  options.homelab.services.gotify = {
    enable = lib.mkEnableOption "Gotify push notification server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gotify-server";
      description = "Directory where Gotify stores its data (database, uploads, plugins).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.gotify = {
      enable = true;
      environment = {
        GOTIFY_SERVER_PORT = 8050;
      };
    };

    # Static user so we can own virtiofs data without DynamicUser conflicts
    users.users.gotify = {
      isSystemUser = true;
      group = "gotify";
      home = cfg.dataDir;
    };
    users.groups.gotify = {};

    # Override upstream service to use static user and custom data dir
    systemd.services.gotify-server.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "gotify";
      Group = "gotify";
      WorkingDirectory = lib.mkForce cfg.dataDir;
      StateDirectory = lib.mkForce "";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "gotify.ablz.au";
          port = 8050;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Gotify";
          url = "https://gotify.ablz.au/";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [8050];
  };
}
