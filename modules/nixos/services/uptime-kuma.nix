{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.uptime-kuma;
in {
  options.homelab.services.uptime-kuma = {
    enable = lib.mkEnableOption "Uptime Kuma status monitoring";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/uptime-kuma";
      description = "Directory for Uptime Kuma data (SQLite DB, screenshots, etc).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.uptime-kuma = {
      enable = true;
      settings = {
        PORT = "3001";
        HOST = "0.0.0.0";
        DATA_DIR = lib.mkForce cfg.dataDir;
      };
    };

    # Static user so we can own virtiofs data without DynamicUser conflicts
    users.users.uptime-kuma = {
      isSystemUser = true;
      group = "uptime-kuma";
      home = cfg.dataDir;
    };
    users.groups.uptime-kuma = {};

    # Override upstream service to use static user and custom data dir
    systemd.services.uptime-kuma.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "uptime-kuma";
      Group = "uptime-kuma";
      WorkingDirectory = lib.mkForce cfg.dataDir;
      StateDirectory = lib.mkForce "";
      ReadWritePaths = [cfg.dataDir];
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "status.ablz.au";
          port = 3001;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Uptime Kuma";
          url = "https://status.ablz.au/";
        }
      ];

      # Fleet-wide maintenance window covering nightly auto-updates.
      #
      # Why this exists: `homelab.update` runs on every host between 01:00
      # and 04:00 AWST with a 60-minute randomized delay, plus GC and kernel
      # reboots. Before this window existed, every rebuild blipped all
      # ~26 monitors and Gotify-paged for every DOWN→UP transition, training
      # us to ignore alerts — which is how we missed immich being down for
      # three days. See `modules/nixos/autoupdate/update.nix` for the schedule.
      #
      # The window covers 00:45 → 05:30 AWST, which is the earliest possible
      # rebuild start through the latest possible kernel reboot completion.
      # It deliberately re-opens alerting at 05:30 so that if maintenance
      # itself breaks something, we still get paged during normal hours.
      #
      # Defined here (and only here) because this is the host that runs
      # Uptime Kuma — keeping the declaration single-homed avoids cross-host
      # races in the sync service.
      monitoring.maintenanceWindows = [
        {
          title = "nightly-rebuilds";
          description = "Silence alerts during fleet auto-update window (homelab.update).";
          startTime = "00:45";
          endTime = "05:30";
          timezone = "Australia/Perth";
        }
      ];
    };
  };
}
