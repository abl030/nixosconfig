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

    # Blank /mnt (#257). Stateless PDF toolkit — no /mnt access needed, so
    # mask the host's /mnt/* tree entirely. TemporaryFileSystem forces a
    # private mount namespace on its own (upstream leaves PrivateMounts=no).
    # No bind source, so no NAMESPACE errorPattern: a tmpfs-only namespace
    # has nothing to fail on, and liveness is covered by the Kuma monitor.
    # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
    systemd.services.stirling-pdf.serviceConfig.TemporaryFileSystem = "/mnt";

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
