{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.audiobookshelf;
in {
  options.homelab.services.audiobookshelf = {
    enable = lib.mkEnableOption "Audiobookshelf audiobook/podcast server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/audiobookshelf";
      description = "Directory where Audiobookshelf stores its data (database, metadata, settings).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.audiobookshelf = {
      enable = true;
      port = 13378;
      host = "0.0.0.0";
    };

    # Add audiobookshelf user to users group for NFS media access
    # (audiobook dirs are gid=users with setgid)
    users.users.audiobookshelf.extraGroups = ["users"];

    # Override upstream service to use custom data dir (virtiofs)
    systemd.services.audiobookshelf.serviceConfig = {
      WorkingDirectory = lib.mkForce cfg.dataDir;
      StateDirectory = lib.mkForce "";
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "audiobooks.ablz.au";
          port = 13378;
          websocket = true;
        }
        {
          host = "audiobook.ablz.au";
          port = 13378;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Audiobookshelf";
          url = "https://audiobooks.ablz.au/";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [13378];
  };
}
