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

    systemd = {
      services = {
        # Override upstream service to use custom data dir (virtiofs)
        audiobookshelf.serviceConfig = {
          WorkingDirectory = lib.mkForce cfg.dataDir;
          StateDirectory = lib.mkForce "";
        };

        # Weekly cleanup of embed-metadata backups (originals stashed by ABS
        # when the API embed endpoint writes tags into audio files)
        audiobookshelf-cache-cleanup = {
          description = "Purge Audiobookshelf embed-metadata backup cache";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe' config.systemd.package "rm"} -rf ${cfg.dataDir}/metadata/cache/items";
            User = "audiobookshelf";
          };
        };
      };

      timers.audiobookshelf-cache-cleanup = {
        description = "Weekly Audiobookshelf cache cleanup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "audiobook.ablz.au";
          port = 13378;
          websocket = true;
        }
      ];

      tailscaleShare.audiobookshelf = {
        enable = true;
        fqdn = "audiobooks.ablz.au";
        upstream = "http://host.docker.internal:13378";
        dataDir = "/mnt/virtio/tailscale-share/audiobookshelf";
        hostname = "audiobookshelf";
        authKeySecret = null;
        firewallPorts = [13378];
        monitorName = "Audiobookshelf (Tailnet)";
      };

      monitoring.monitors = [
        {
          name = "Audiobookshelf (LAN)";
          url = "https://audiobook.ablz.au/";
        }
      ];
    };
  };
}
