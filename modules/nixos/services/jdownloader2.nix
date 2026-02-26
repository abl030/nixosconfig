{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.jdownloader2;
in {
  options.homelab.services.jdownloader2 = {
    enable = lib.mkEnableOption "JDownloader2 download manager (OCI container)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jdownloader2";
      description = "Directory where JDownloader2 stores its config.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media";
      description = "Root media path for download outputs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5800;
      description = "Port for the JDownloader2 web UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = ["podman-jdownloader2.service"];

      localProxy.hosts = [
        {
          host = "download.ablz.au";
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "JDownloader2";
          url = "https://download.ablz.au/";
        }
      ];
    };

    virtualisation.oci-containers.containers.jdownloader2 = {
      image = "docker.io/jlesage/jdownloader-2:latest";
      autoStart = true;
      pull = "always";
      ports = ["${toString cfg.port}:5800"];
      volumes = [
        "${cfg.dataDir}:/config"
        "${cfg.mediaDir}/Temp:/output"
        "${cfg.mediaDir}/Books/Unsorted/Books:/books"
      ];
      environment = {
        TZ = "Australia/Perth";
        USER_ID = "0";
        GROUP_ID = "0";
        UMASK = "0002";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
    ];
  };
}
