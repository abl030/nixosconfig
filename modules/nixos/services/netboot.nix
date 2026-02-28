{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.netboot;
in {
  options.homelab.services.netboot = {
    enable = lib.mkEnableOption "netboot.xyz PXE boot server (OCI container)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/netboot";
      description = "Directory for netboot.xyz config and assets.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3005;
      description = "Port for the netboot.xyz web UI.";
    };

    assetsPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for the assets HTTP server (PXE clients fetch boot files here).";
    };

    tftpPort = lib.mkOption {
      type = lib.types.port;
      default = 1069;
      description = "Host UDP port for TFTP (PXE boot). Mapped to container port 69.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-netboot.service";
          image = "ghcr.io/netbootxyz/netbootxyz:latest";
        }
      ];

      localProxy.hosts = [
        {
          host = "netboot.ablz.au";
          port = cfg.webPort;
        }
      ];

      monitoring.monitors = [
        {
          name = "Netboot";
          url = "https://netboot.ablz.au/";
        }
      ];
    };

    virtualisation.oci-containers.containers.netboot = {
      image = "ghcr.io/netbootxyz/netbootxyz:latest";
      autoStart = true;
      pull = "newer";
      ports = [
        "${toString cfg.webPort}:3000"
        "${toString cfg.assetsPort}:80"
        "${toString cfg.tftpPort}:69/udp"
      ];
      volumes = [
        "${cfg.dataDir}/config:/config"
        "${cfg.dataDir}/assets:/assets"
      ];
      environment = {
        NGINX_PORT = "80";
        WEB_APP_PORT = "3000";
      };
    };

    # TFTP + assets ports must be reachable by PXE clients on the LAN
    networking.firewall.allowedTCPPorts = [cfg.assetsPort];
    networking.firewall.allowedUDPPorts = [cfg.tftpPort];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
      "d ${cfg.dataDir}/config 0755 root root - -"
      "d ${cfg.dataDir}/assets 0755 root root - -"
    ];
  };
}
