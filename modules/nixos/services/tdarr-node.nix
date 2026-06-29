# See docs/wiki/services/tdarr-node.md for role, passthrough, and gotchas.
# See docs/wiki/infrastructure/igpu-passthrough.md for /dev/dri health checks.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.tdarrNode;
  tdarrUid = 2010;
  tdarrGid = 2010;
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

    renderDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/renderD128";
      description = ''
        Host DRM render node passed to the container for VAAPI. Defaults to
        renderD128, but on a host with multiple GPUs the iGPU may enumerate at a
        different node (e.g. renderD129 in the igpu LXC, where the GTX 1080 takes
        renderD128). Set this to the actual iGPU render node.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      users.tdarr = {
        isSystemUser = true;
        uid = tdarrUid;
        group = "tdarr";
        extraGroups = ["users" "render" "video"];
        home = cfg.dataDir;
      };
      groups.tdarr.gid = tdarrGid;
    };

    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-tdarr-node.service";
          inherit (cfg) image;
        }
      ];

      nfsWatchdog.podman-tdarr-node.path = "${cfg.mediaRoot}/Movies";
    };

    virtualisation.oci-containers.containers.tdarr-node = {
      inherit (cfg) image;
      autoStart = true;
      pull = "newer";
      environment = {
        TZ = "Australia/Perth";
        PUID = toString tdarrUid;
        PGID = "100";
        UMASK_SET = "002";
        inherit (cfg) nodeName;
        serverIP = cfg.serverIp;
        serverPort = toString cfg.serverPort;
        inContainer = "true";
        ffmpegVersion = "7";
      };
      volumes = [
        "${cfg.dataDir}/configs:/app/configs:rw"
        "${cfg.dataDir}/logs:/app/logs:rw"
        "${cfg.mediaRoot}/Movies:/mnt/media/Movies:ro"
        "${cfg.mediaRoot}/TV Shows:/mnt/media/TV Shows:ro"
        "${cfg.transcodeTemp}:/temp:rw"
      ];
      # Upstream s6 init starts as root, chowns state, then drops to PUID/PGID,
      # so it needs the file-ownership + setuid/setgid drop caps; cap-drop=all
      # removes everything else. GPU access is device-perm based, not a cap.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--cap-add=CHOWN"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=KILL"
          # Pass the iGPU render node through UNCHANGED (same path in/out). Do NOT
          # rename it to renderD128: mesa/libva resolve the GPU via /sys/class/drm/
          # <name>, and on a multi-GPU host renderD128 is a DIFFERENT card's sysfs,
          # so a rename makes VAAPI init fail ("Cannot open a VA display").
          "--device=${cfg.renderDevice}:${cfg.renderDevice}"
        ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
      "d ${cfg.dataDir}/configs 0750 tdarr tdarr - -"
      "d ${cfg.dataDir}/logs 0750 tdarr tdarr - -"
      "Z ${cfg.dataDir}/configs - tdarr tdarr - -"
      "Z ${cfg.dataDir}/logs - tdarr tdarr - -"
    ];

    systemd.services.podman-tdarr-node = {
      requires = ["mnt-data.mount"];
      after = ["mnt-data.mount" "network-online.target"];
      wants = ["network-online.target"];
    };
  };
}
