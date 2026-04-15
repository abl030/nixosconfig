{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.tdarrNode;
in {
  options.homelab.services.tdarrNode = {
    enable = lib.mkEnableOption "Tdarr worker node (OCI container with /dev/dri passthrough)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/docker/tdarr";
      description = "Directory for tdarr node configs and logs (subdirs: configs/, logs/).";
    };

    mediaRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media";
      description = "Host path holding the media tree; mounted to /mnt/media inside the container.";
    };

    transcodeTemp = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Transcode Temp";
      description = "Host path for transcode scratch space; mounted to /temp inside the container.";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = "IGPNode";
      description = "Node name reported to the Tdarr server.";
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.2";
      description = "Tdarr server address (runs on tower/Unraid).";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 8266;
      description = "Tdarr server port.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/haveagitgat/tdarr_node:latest";
      description = "Tdarr node container image.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-tdarr-node.service";
          inherit (cfg) image;
        }
      ];

      nfsWatchdog.podman-tdarr-node.path = cfg.mediaRoot;
    };

    virtualisation.oci-containers.containers.tdarr-node = {
      inherit (cfg) image;
      autoStart = true;
      pull = "newer";
      environment = {
        TZ = "Australia/Perth";
        PUID = "0";
        PGID = "0";
        UMASK_SET = "002";
        nodeName = cfg.nodeName;
        serverIP = cfg.serverIp;
        serverPort = toString cfg.serverPort;
        inContainer = "true";
        ffmpegVersion = "7";
      };
      volumes = [
        "${cfg.dataDir}/configs:/app/configs"
        "${cfg.dataDir}/logs:/app/logs"
        "${cfg.mediaRoot}:/mnt/media"
        "${cfg.transcodeTemp}:/temp"
      ];
      extraOptions = ["--device=/dev/dri:/dev/dri"];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
      "d ${cfg.dataDir}/configs 0755 root root - -"
      "d ${cfg.dataDir}/logs 0755 root root - -"
    ];

    systemd.services.podman-tdarr-node = {
      requires = ["mnt-data.mount"];
      after = ["mnt-data.mount" "network-online.target"];
      wants = ["network-online.target"];
    };
  };
}
