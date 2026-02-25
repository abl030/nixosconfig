{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.atuin;
in {
  options.homelab.services.atuin = {
    enable = lib.mkEnableOption "Atuin shell history sync server (native NixOS module)";
  };

  config = lib.mkIf cfg.enable {
    services.atuin = {
      enable = true;
      port = 8888;
      host = "0.0.0.0";
      openRegistration = true;
      database.createLocally = true;
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

    networking.firewall.allowedTCPPorts = [8888];
  };
}
