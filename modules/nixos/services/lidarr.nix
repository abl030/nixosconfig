{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.lidarr;
in {
  options.homelab.services.lidarr = {
    enable = lib.mkEnableOption "Lidarr music management (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/lidarr/.config/Lidarr";
      description = "Directory where Lidarr stores its data (config, database, logs).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.lidarr = {
      enable = true;
      inherit (cfg) dataDir;
      openFirewall = false;
    };

    # Add lidarr user to users group for NFS media access
    users.users.lidarr.extraGroups = ["users"];

    # Override upstream tmpfiles to use custom data dir on virtiofs
    systemd.services.lidarr = {
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
      serviceConfig = {
        # Upstream creates dataDir via tmpfiles; override if using virtiofs
        ExecStart = lib.mkForce "${config.services.lidarr.package}/bin/Lidarr -nobrowser -data='${cfg.dataDir}'";
      };
    };

    homelab = {
      nfsWatchdog.lidarr.path = "/mnt/data/Media/Music";

      localProxy.hosts = [
        {
          host = "lidarr.ablz.au";
          port = 8686;
        }
      ];

      monitoring.monitors = [
        {
          name = "Lidarr";
          url = "https://lidarr.ablz.au/ping";
        }
      ];
    };

    # Port 8686 intentionally NOT opened in firewall — accessed via nginx (localProxy) only
  };
}
