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
      port = cfg.port;
      configDir = cfg.dataDir;
    };

    # Static user — predictable UID required for virtiofs file ownership.
    # DynamicUser gives random UIDs that don't survive across restarts.
    users.users.seerr = {
      isSystemUser = true;
      group = "seerr";
    };
    users.groups.seerr = {};

    # Override DynamicUser: assign the static seerr user and grant write access
    # to the virtiofs path. ProtectSystem=strict (upstream) blocks writes by
    # default; ReadWritePaths= exempts our dataDir.
    systemd.services.seerr.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "seerr";
      Group = "seerr";
      StateDirectory = lib.mkForce "";
      ReadWritePaths = [cfg.dataDir];
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
          port = cfg.port;
        }
      ];

      monitoring.monitors = [
        {
          name = "Overseerr";
          url = "https://request.ablz.au/api/v1/status";
        }
      ];
    };
  };
}
