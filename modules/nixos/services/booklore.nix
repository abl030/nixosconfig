# Independent read-only view of Calibre files; no migration. See book-platform-exploration.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.booklore;
  image = "ghcr.io/booklore-app/booklore:latest";
  lan = config.homelab.localProxy.localIp;
  existing = "/mnt/data/Media/Books/Calibre LIbrary";
  dbSecret = config.sops.secrets.booklore-env.path;
  db = import ../lib/mk-mariadb-container.nix {
    inherit pkgs;
    name = "booklore";
    hostNum = 11;
    dataDir = "${cfg.dataDir}/database";
    passwordFile = dbSecret;
  };
in {
  options.homelab.services.booklore = {
    enable = lib.mkEnableOption "Booklore OPDS library trial";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/booklore";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 6060;
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.booklore.gid = 2022;
    users.users.booklore = {
      isSystemUser = true;
      uid = 2022;
      group = "booklore";
      extraGroups = ["users"];
    };
    sops.secrets.booklore-env = {
      sopsFile = config.homelab.secrets.sopsFile "booklore.env";
      format = "dotenv";
      mode = "0400";
    };
    containers.booklore-db = db.containerConfig;
    systemd.tmpfiles.rules = (map (p: "d ${cfg.dataDir}/${p} 0750 booklore booklore - -") ["" "data" "bookdrop" "books"]) ++ ["d ${cfg.dataDir}/database 0755 root root - -" "d ${cfg.dataDir}/database/mysql 0755 root root - -"];
    networking.firewall.allowedTCPPorts = [cfg.port];
    virtualisation.oci-containers.containers.booklore = {
      inherit image;
      ports = ["${lan}:${toString cfg.port}:6060" "127.0.0.1:${toString cfg.port}:6060"];
      environmentFiles = [dbSecret];
      environment = {
        USER_ID = "2022";
        GROUP_ID = "100";
        TZ = "Australia/Perth";
        DATABASE_URL = "jdbc:mariadb://${db.dbHost}:3306/booklore";
        DATABASE_USERNAME = "booklore";
        # NFS originals are also mounted read-only at the kernel boundary.
        DISK_TYPE = "NETWORK";
        JAVA_TOOL_OPTIONS = "-XX:MaxRAMPercentage=65.0";
      };
      volumes = ["${cfg.dataDir}/data:/app/data" "${cfg.dataDir}/bookdrop:/bookdrop" "${cfg.dataDir}/books:/books/trial" "/mnt/booklore-existing:/books/existing:ro"];
      # Upstream init creates the application UID then uses su-exec.
      extraOptions = config.homelab.podman.hardenOptions ++ ["--cap-add=CHOWN" "--cap-add=SETUID" "--cap-add=SETGID" "--cap-add=DAC_OVERRIDE" "--memory=3g" "--pids-limit=384"];
    };
    systemd.services.podman-booklore = {
      after = ["container@booklore-db.service"];
      requires = ["container@booklore-db.service"];
      restartTriggers = [config.systemd.units."container@booklore-db.service".unit dbSecret];
      unitConfig.RequiresMountsFor = [cfg.dataDir "\"${existing}\""];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
        BindReadOnlyPaths = ["\"${existing}:/mnt/booklore-existing\""];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-booklore.service";
        inherit image;
      }
    ];
    homelab.nfsWatchdog.podman-booklore.path = existing;
    homelab.monitoring = {
      monitors = [
        {
          name = "Booklore trial";
          url = "http://doc2:${toString cfg.port}/api/v1/healthcheck";
        }
      ];
      deepProbes = [
        {
          name = "Booklore trial state";
          command = "${pkgs.callPackage ./probes/check-book-trial.nix {}}/bin/check-book-trial booklore ${cfg.dataDir} ${toString cfg.port}";
          interval = "5m";
          intervalSecs = 300;
        }
      ];
      errorPatterns = [
        {
          name = "Booklore migration failure";
          unit = "podman-booklore.service";
          pattern = "FlywayException|MigrationFailedException|APPLICATION FAILED TO START";
          severity = "critical";
          summary = "Booklore trial failed database migration or startup";
          threshold = 0;
        }
      ];
    };
  };
}
