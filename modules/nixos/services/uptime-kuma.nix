{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.uptime-kuma;
in {
  options.homelab.services.uptime-kuma = {
    enable = lib.mkEnableOption "Uptime Kuma status monitoring";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/uptime-kuma";
      description = "Directory for Uptime Kuma data (SQLite DB, screenshots, etc).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.uptime-kuma = {
      enable = true;
      settings = {
        PORT = "3001";
        HOST = "0.0.0.0";
        DATA_DIR = lib.mkForce cfg.dataDir;
      };
    };

    # Static user so we can own virtiofs data without DynamicUser conflicts
    users.users.uptime-kuma = {
      isSystemUser = true;
      group = "uptime-kuma";
      home = cfg.dataDir;
    };
    users.groups.uptime-kuma = {};

    # Override upstream service to use static user and custom data dir
    systemd.services.uptime-kuma.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "uptime-kuma";
      Group = "uptime-kuma";
      WorkingDirectory = lib.mkForce cfg.dataDir;
      StateDirectory = lib.mkForce "";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "status.ablz.au";
          port = 3001;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Uptime Kuma";
          url = "https://status.ablz.au/";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [3001];
  };
}
