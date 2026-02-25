{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.immich;
in {
  options.homelab.services.immich = {
    enable = lib.mkEnableOption "Immich photo management (native NixOS module)";
  };

  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      port = 2283;
      host = "0.0.0.0";
      mediaLocation = "/mnt/data/Life/Photos";

      database = {
        enable = true;
        createDB = true;
        enableVectorChord = true;
        enableVectors = true;
      };

      redis.enable = true;
      machine-learning.enable = true;

      secretsFile = config.sops.secrets."immich/env".path;

      environment = {
        IMMICH_TELEMETRY_INCLUDE = "all";
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://192.168.1.33:4317";
        OTEL_TRACES_EXPORTER = "otlp";
        OTEL_SERVICE_NAME = "immich";
        IMMICH_METRICS = "true";
        IMMICH_METRICS_PORT = "8081";
      };
    };

    # Sops secret for Immich env (DB_PASSWORD, DB_USERNAME, DB_DATABASE_NAME)
    sops.secrets."immich/env" = {
      sopsFile = config.homelab.secrets.sopsFile "immich.env";
      format = "dotenv";
      owner = "immich";
      group = "immich";
      mode = "0400";
    };

    # Wire into existing infrastructure
    homelab = {
      localProxy.hosts = [
        {
          host = "photos.ablz.au";
          port = 2283;
          websocket = true;
          maxBodySize = "0";
        }
      ];

      monitoring.monitors = [
        {
          name = "Immich";
          url = "https://photos.ablz.au/api/server/ping";
        }
      ];

      loki.extraScrapeTargets = [
        {
          job = "immich";
          address = "localhost:8081";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [8081];
  };
}
