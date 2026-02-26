{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.webdav;
in {
  options.homelab.services.webdav = {
    enable = lib.mkEnableOption "WebDAV file server";
  };

  config = lib.mkIf cfg.enable {
    services.webdav = {
      enable = true;
      environmentFile = config.sops.secrets."webdav/env".path;
      settings = {
        address = "0.0.0.0";
        port = 9090;
        directory = "/mnt/data/Life/Andy/Education/Zotero Library";
        permissions = "CRUD";
        users = [
          {
            username = "{env}WEBDAV_USERNAME";
            password = "{env}WEBDAV_PASSWORD";
          }
        ];
      };
    };

    # WebDAV needs NFS mount for Zotero library
    systemd.services.webdav = {
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
    };

    sops.secrets."webdav/env" = {
      sopsFile = config.homelab.secrets.sopsFile "webdav.env";
      format = "dotenv";
      owner = "webdav";
      mode = "0400";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "webdav.ablz.au";
          port = 9090;
        }
      ];

      monitoring.monitors = [
        {
          name = "WebDav";
          url = "https://webdav.ablz.au/";
          acceptedStatusCodes = ["200-299" "300-399" "401"];
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [9090];
  };
}
