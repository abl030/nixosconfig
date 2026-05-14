{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.youtarr;
  dbSecret = config.sops.secrets."youtarr-db".path;
  youtarrUid = 2009;
  youtarrGid = 2009;

  # Pinned 2026-05-14 while extracting MariaDB from upstream's EOL
  # mariadb:10.3 compose default. See docs/wiki/services/youtarr.md.
  youtarrImage = "docker.io/dialmaster/youtarr@sha256:8c891a4f96e7b7c37d9915e7b78b919fe03f0aacd87eab76d751f761003e5ee1";

  mdbc = import ../lib/mk-mariadb-container.nix {
    inherit pkgs;
    name = "youtarr";
    hostNum = 9;
    dataDir = "${cfg.dataDir}/mariadb-nspawn";
    passwordFile = "/run/secrets/youtarr-db";
  };

  migrationMarker = "${cfg.dataDir}/mariadb-nspawn/imported-from-oci";
  migrationGate = pkgs.writeShellScript "youtarr-db-migration-gate" ''
    if [ -e "${migrationMarker}" ]; then
      exit 0
    fi

    if [ -d "${cfg.dataDir}/database/mysql" ]; then
      echo "Legacy Youtarr MariaDB state exists at ${cfg.dataDir}/database; restore it into container@youtarr-db.service and touch ${migrationMarker} before starting Youtarr." >&2
      exit 1
    fi

    exit 0
  '';
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
    users = {
      users.youtarr = {
        isSystemUser = true;
        uid = youtarrUid;
        group = "youtarr";
        extraGroups = ["users"];
        home = cfg.dataDir;
      };
      groups.youtarr.gid = youtarrGid;
    };

    homelab = {
      nfsWatchdog.podman-youtarr.path = "${cfg.mediaDir}/YouTube";

      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-youtarr.service";
          image = youtarrImage;
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

    sops.secrets."youtarr-db" = {
      sopsFile = config.homelab.secrets.sopsFile "youtarr-db.env";
      format = "dotenv";
      mode = "0400";
    };

    containers.youtarr-db = mdbc.containerConfig;

    systemd = {
      services.podman-youtarr = {
        after = ["container@youtarr-db.service"];
        requires = ["container@youtarr-db.service"];
        restartTriggers = [
          config.systemd.units."container@youtarr-db.service".unit
          dbSecret
        ];
        serviceConfig.ExecCondition = migrationGate;
      };

      tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 root root - -"
        "d ${cfg.dataDir}/config 0750 youtarr youtarr - -"
        "d ${cfg.dataDir}/images 0750 youtarr youtarr - -"
        "d ${cfg.dataDir}/jobs 0750 youtarr youtarr - -"
        "Z ${cfg.dataDir}/config - youtarr youtarr - -"
        "Z ${cfg.dataDir}/images - youtarr youtarr - -"
        "Z ${cfg.dataDir}/jobs - youtarr youtarr - -"
        "d ${cfg.dataDir}/mariadb-nspawn 0755 root root - -"
        "d ${cfg.dataDir}/mariadb-nspawn/mysql 0755 root root - -"
      ];
    };

    virtualisation.oci-containers.containers.youtarr = {
      image = youtarrImage;
      autoStart = true;
      ports = ["${toString cfg.port}:3011"];
      environmentFiles = [dbSecret];
      environment = {
        TZ = "Australia/Perth";
        # Upstream only uses these values for permission diagnostics. Podman's
        # --user below is what actually makes the Node.js process non-root.
        YOUTARR_UID = toString youtarrUid;
        YOUTARR_GID = "100";
        YOUTUBE_OUTPUT_DIR = "/usr/src/app/data";
        DB_HOST = mdbc.dbHost;
        DB_PORT = toString mdbc.dbPort;
        DB_NAME = "youtarr";
        DB_USER = "youtarr";
        AUTH_ENABLED = "false";
      };
      volumes = [
        "${cfg.mediaDir}/YouTube:/usr/src/app/data:rw"
        "${cfg.dataDir}/config:/app/config:rw"
        "${cfg.dataDir}/images:/app/server/images:rw"
        "${cfg.dataDir}/jobs:/app/jobs:rw"
      ];
      extraOptions = [
        "--user=${toString youtarrUid}:100"
      ];
    };
  };
}
