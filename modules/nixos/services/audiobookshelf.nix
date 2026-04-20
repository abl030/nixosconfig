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

    # Weekly cleanup of embed-metadata backups (originals stashed by ABS
    # when the API embed endpoint writes tags into audio files)
    systemd.services.audiobookshelf-cache-cleanup = {
      description = "Purge Audiobookshelf embed-metadata backup cache";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe' config.systemd.package "rm"} -rf ${cfg.dataDir}/metadata/cache/items";
        User = "audiobookshelf";
      };
    };

    systemd.timers.audiobookshelf-cache-cleanup = {
      description = "Weekly Audiobookshelf cache cleanup";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
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
  };
}
