{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.stirlingpdf;
in {
  options.homelab.services.stirlingpdf = {
    enable = lib.mkEnableOption "Stirling PDF toolkit";
  };

  config = lib.mkIf cfg.enable {
    services.stirling-pdf = {
      enable = true;
      environment = {
        SERVER_PORT = 8083;
        LANGS = "en_GB";
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "pdf.ablz.au";
          port = 8083;
        }
      ];

      monitoring.monitors = [
        {
          name = "StirlingPDF";
          url = "https://pdf.ablz.au/";
        }
      ];

      # See #253 audit. Skipped — stateless PDF tools service with no
      # actionable failure log fingerprint; outages surface via the Kuma
      # HTTP monitor above.
      monitoring.errorPatterns = [];
    };
  };
}
