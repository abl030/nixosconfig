{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.youtarr;
in {
  options.homelab.services.youtarr = {
    enable = lib.mkEnableOption "Youtarr YouTube-to-arr bridge (OCI containers)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/youtarr";
      description = "Directory for Youtarr app state and MariaDB data.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media";
      description = "Root media path (YouTube downloads go to Media/YouTube).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3087;
      description = "Host port for the Youtarr web UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-youtarr.service";
          image = "docker.io/dialmaster/youtarr:latest";
        }
        {
          unit = "podman-youtarr-db.service";
          image = "docker.io/library/mariadb:10.3";
        }
      ];

      localProxy.hosts = [
        {
          host = "youtarr.ablz.au";
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "Youtarr";
          url = "https://youtarr.ablz.au/";
        }
      ];
    };

    # Create a shared podman network so containers can resolve each other by name
    systemd.services.podman-network-youtarr = {
      description = "Create podman network for Youtarr";
      before = ["podman-youtarr.service" "podman-youtarr-db.service"];
      requiredBy = ["podman-youtarr.service" "podman-youtarr-db.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.virtualisation.podman.package}/bin/podman network create youtarr --ignore";
      };
    };

    virtualisation.oci-containers.containers.youtarr = {
      image = "docker.io/dialmaster/youtarr:latest";
      autoStart = true;
      pull = "newer";
      ports = ["${toString cfg.port}:3011"];
      dependsOn = ["youtarr-db"];
      environment = {
        TZ = "Australia/Perth";
        YOUTARR_UID = "0";
        YOUTARR_GID = "0";
        YOUTUBE_OUTPUT_DIR = "/usr/src/app/data";
        DB_HOST = "youtarr-db";
        DB_PORT = "3306";
        DB_NAME = "youtarr";
        DB_USER = "youtarr";
        DB_PASSWORD = "youtarr";
        AUTH_ENABLED = "false";
      };
      volumes = [
        "${cfg.mediaDir}/YouTube:/usr/src/app/data"
        "${cfg.dataDir}/config:/app/config"
        "${cfg.dataDir}/images:/app/server/images"
        "${cfg.dataDir}/jobs:/app/jobs"
      ];
      extraOptions = ["--network=youtarr"];
    };

    virtualisation.oci-containers.containers.youtarr-db = {
      image = "docker.io/library/mariadb:10.3";
      autoStart = true;
      pull = "newer";
      cmd = ["--character-set-server=utf8mb4" "--collation-server=utf8mb4_unicode_ci" "--tc-heuristic-recover=rollback"];
      environment = {
        MYSQL_DATABASE = "youtarr";
        MYSQL_USER = "youtarr";
        MYSQL_PASSWORD = "youtarr";
        MYSQL_ROOT_PASSWORD = "youtarr";
      };
      volumes = [
        "${cfg.dataDir}/database:/var/lib/mysql:U"
      ];
      extraOptions = ["--network=youtarr"];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
      "d ${cfg.dataDir}/config 0755 root root - -"
      "d ${cfg.dataDir}/images 0755 root root - -"
      "d ${cfg.dataDir}/jobs 0755 root root - -"
      "d ${cfg.dataDir}/database 0755 root root - -"
    ];
  };
}
