{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.overseerr;
in {
  options.homelab.services.overseerr = {
    enable = lib.mkEnableOption "Seerr media request manager (Overseerr successor)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/seerr";
      description = "Directory where Seerr stores its config and database.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5055;
      description = "Port Seerr listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Use the nixpkgs services.seerr module (hierarchy rule #1).
    # configDir sets CONFIG_DIRECTORY env var — points directly to virtiofs path.
    services.seerr = {
      enable = true;
      inherit (cfg) port;
      configDir = cfg.dataDir;
    };

    # Static user — predictable UID required for virtiofs file ownership.
    # DynamicUser gives random UIDs that don't survive across restarts.
    users.users.seerr = {
      isSystemUser = true;
      group = "seerr";
    };
    users.groups.seerr = {};

    # Override DynamicUser: assign the static seerr user.
    systemd.services.seerr = {
      # Order after the virtiofs mount and pull it in, so the fail-loud
      # BindPaths below can't race the mount at boot.
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "seerr";
        Group = "seerr";
        StateDirectory = lib.mkForce "";
        # Blank /mnt + bind only our virtiofs config dir (#257). Was: broad ro
        # view of all /mnt/* plus dataDir rw via ReadWritePaths (silent-skip).
        # BindPaths is fail-loud, paired with the NAMESPACE errorPattern below.
        # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };

    # Create data directory on first boot, owned by the static seerr user.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 seerr seerr - -"
    ];

    homelab = {
      # LAN-accessible URL: nginx + ACME + Cloudflare DNS → doc2's local IP.
      # Used by local family and Uptime Kuma monitoring.
      localProxy.hosts = [
        {
          host = "request.ablz.au";
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "Overseerr";
          url = "https://request.ablz.au/api/v1/status";
        }
      ];

      # See #253 audit. Overseerr container produced no actionable
      # error logs in the 30-day window; real outages flow through
      # the Kuma HTTP monitor above and through the tailscale-share
      # sidecar pattern in tailscale-share.nix.
      #
      # NAMESPACE/bind start-failures (#257) page ONCE via the fleet-wide
      # "Service failed to start (sandbox/namespace)" alert in alerting.nix —
      # no per-service entry, so one stale mount can't fan out into N identical
      # critical pages (storm de-collide 2026-06-26).
      monitoring.errorPatterns = []; # ^ namespace → fleet alert; real outages → Kuma
    };
  };
}
