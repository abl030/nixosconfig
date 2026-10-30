# Edge traffic for family.barrett-lennard.com (#250): requests, bytes, cache
# hits, response codes and countries from Cloudflare's aggregate analytics,
# as Prometheus counters for Mimir/Grafana. Runs on doc2 beside the familypub
# guest but has nothing to do with it: it only calls Cloudflare's API with a
# zone Analytics Read token. No client addresses are read or stored.
# See docs/wiki/services/family-public-site.md.
{
  config,
  pkgs,
  ...
}: let
  port = 9472;
  exporter = pkgs.writers.writePython3Bin "familypub-cf-exporter" {
    flakeIgnore = ["E501"];
  } (builtins.readFile ./family-public-metrics.py);
in {
  sops.secrets."family-public/cf-analytics" = {
    sopsFile = config.homelab.secrets.sopsFile "family-public-cf-analytics";
    format = "binary";
    mode = "0400";
  };

  systemd.services.familypub-cf-exporter = {
    description = "Cloudflare edge analytics for family.barrett-lennard.com";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    environment = {
      CF_ZONE = "3312c076271b9036adcbd0ec5df55dda";
      CF_HOST = "family.barrett-lennard.com";
      CF_TOKEN_FILE = "%d/token";
      LISTEN_PORT = toString port;
    };
    serviceConfig = {
      ExecStart = "${exporter}/bin/familypub-cf-exporter";
      LoadCredential = "token:${config.sops.secrets."family-public/cf-analytics".path}";
      DynamicUser = true;
      StateDirectory = "familypub-cf-exporter";
      Restart = "on-failure";
      RestartSec = "30s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = "";
    };
  };

  # LOCALHOST-ONLY: scraped by this host's alloy and remote_written to Mimir.
  homelab.loki.extraScrapeTargets = [
    {
      job = "familypub-cf";
      address = "localhost:${toString port}";
      instance = "family.barrett-lennard.com";
    }
  ];
}
