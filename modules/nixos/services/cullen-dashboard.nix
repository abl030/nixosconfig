{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.cullen-dashboard;
in {
  options.homelab.services.cullen-dashboard = {
    enable = lib.mkEnableOption "Cullen winery dashboards (static HTML/CSV served via python http.server)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${hostConfig.user}/cullen/dashboards";
      description = "Directory containing dashboard HTML/CSV files.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "cullen.ablz.au";
      description = "Public FQDN for the dashboards. Cloudflare A record is synced to homelab.localProxy.localIp.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8421;
      description = "Loopback port for the static file server. Nginx proxies https://fqdn to 127.0.0.1:<port>. 8000 is reserved for ad-hoc testing.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User to run the static server as. Needs read access to dataDir.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cullen-dashboard = {
      description = "Cullen winery static dashboard server";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString cfg.port} --bind 127.0.0.1 --directory ${cfg.dataDir}";
        Restart = "on-failure";
        RestartSec = "5s";
        User = cfg.user;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = cfg.port;
      }
    ];
  };
}
