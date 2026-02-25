{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.tautulli;
in {
  options.homelab.services.tautulli = {
    enable = lib.mkEnableOption "Tautulli Plex monitoring (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/plexpy";
      description = "Directory where Tautulli stores its data.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tautulli = {
      enable = true;
      port = 8181;
      inherit (cfg) dataDir;
      configFile = "${cfg.dataDir}/config.ini";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "tau.ablz.au";
          port = 8181;
        }
      ];

      monitoring.monitors = [
        {
          name = "Tautulli";
          url = "https://tau.ablz.au/";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [8181];
  };
}
