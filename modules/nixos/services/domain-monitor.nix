{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.domain-monitor;

  # ===== DOMAIN LIST — edit here to add/remove domains =====
  workDomains = [
    "cullenswine.com"
    "cullenswine.com.au"
    "cullenswine.au"
    "cullenswines.com"
    "cullenswines.com.au"
    "cullenswines.au"
    "cullenwine.com"
    "cullenwine.com.au"
    "cullenwine.au"
    "cullenwines.com"
    "cullenwines.com.au"
    "cullenwines.au"
    "cullenwines.net"
    "cullenwines.net.au"
  ];
  personalDomains = ["ablz.au" "barrett-lennard.com"];

  # Domains that need SSL cert monitoring (have live HTTPS)
  sslDomains = ["cullenwines.com.au"];
  # ===========================================================

  allDomains = workDomains ++ personalDomains;

  # Generate domain expiry endpoints
  domainExpiryEndpoints =
    map (d: {
      name = "${d} registration";
      url = "https://${d}";
      interval = "24h";
      conditions = ["[DOMAIN_EXPIRATION] > 720h"]; # 30 days
      alerts = [{type = "gotify";}];
    })
    allDomains;

  # Generate SSL cert endpoints (only for domains with live HTTPS)
  sslEndpoints =
    map (d: {
      name = "${d} certificate";
      url = "https://${d}";
      interval = "1h";
      conditions = [
        "[CERTIFICATE_EXPIRATION] > 720h" # 30 days
        "[STATUS] < 400"
      ];
      alerts = [{type = "gotify";}];
    })
    sslDomains;
in {
  options.homelab.services.domain-monitor = {
    enable = lib.mkEnableOption "Domain & SSL certificate monitoring via Gatus";
  };

  config = lib.mkIf cfg.enable {
    services.gatus = {
      enable = true;
      environmentFile = config.sops.secrets."gatus/env".path;
      settings = {
        alerting.gotify = {
          server-url = config.homelab.gotify.endpoint;
          token = "\${GOTIFY_TOKEN}";
        };
        endpoints = domainExpiryEndpoints ++ sslEndpoints;
      };
    };

    sops.secrets."gatus/env" = {
      sopsFile = config.homelab.secrets.sopsFile "gotify.env";
      format = "dotenv";
      owner = "root";
      mode = "0444";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "domains.ablz.au";
          port = 8080;
        }
      ];
      monitoring.monitors = [
        {
          name = "Domain Monitor (Gatus)";
          url = "https://domains.ablz.au/";
        }
      ];
    };
  };
}
