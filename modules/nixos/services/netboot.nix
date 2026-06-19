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

      # See #253 audit. Skipped — very simple iPXE/TFTP/HTTP server with
      # no actionable failure log fingerprint; outages surface via the
      # Kuma HTTP monitor above.
      monitoring.errorPatterns = [];
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
        # :U migrates existing abl030-owned content into the userns range on
        # start. /assets is ~2GB so this chown is slow — see TimeoutStartSec.
        "${cfg.dataDir}/config:/config:U"
        "${cfg.dataDir}/assets:/assets:U"
      ];
      environment = {
        NGINX_PORT = "80";
        WEB_APP_PORT = "3000";
      };
      # s6 init runs as root, chowns /config + /assets, then serves nginx/tftp
      # on privileged ports (:80, :69). cap-drop=all + the file-ownership drop
      # caps + NET_BIND_SERVICE for the <1024 binds; everything else removed.
      # userns remap (forgejo#2 Phase 1b): the image's nbxyz app user is UID 1000
      # = host abl030. Remap the whole container so container UID 1000 → host
      # 101000, never abl030. The s6 caps + NET_BIND_SERVICE apply within the
      # userns (privileged-port bind happens in the container's own netns; the
      # host -p publish is done by podman as real root).
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--uidmap=0:100000:65536"
          "--gidmap=0:100000:65536"
          "--cap-add=CHOWN"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=KILL"
          "--cap-add=NET_BIND_SERVICE"
        ];
    };

    # The :U chown of the ~2GB /assets volume on (re)start can take a while;
    # give the unit ample room so podman doesn't kill it mid-migration.
    systemd.services.podman-netboot.serviceConfig.TimeoutStartSec = "600";

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
