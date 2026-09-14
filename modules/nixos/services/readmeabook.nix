# ABS-aware request trial with separate downloads. See book-platform-exploration.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.readmeabook;
  image = "ghcr.io/kikootwo/readmeabook:latest";
  lan = config.homelab.localProxy.localIp;
  dbSecret = config.sops.secrets.readmeabook-env.path;
  db = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "readmeabook";
    hostNum = 13;
    dataDir = "${cfg.dataDir}/database";
    passwordFile = dbSecret;
  };
in {
  options.homelab.services.readmeabook = {
    enable = lib.mkEnableOption "ReadMeABook ABS request trial";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/readmeabook";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3031;
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.readmeabook.gid = 2024;
    users.users.readmeabook = {
      isSystemUser = true;
      uid = 2024;
      group = "readmeabook";
    };
    sops.secrets.readmeabook-env = {
      sopsFile = config.homelab.secrets.sopsFile "readmeabook.env";
      format = "dotenv";
      mode = "0400";
    };
    containers.readmeabook-db = db.containerConfig;
    systemd.tmpfiles.rules = (map (p: "d ${cfg.dataDir}/${p} 0750 readmeabook readmeabook - -") ["config" "cache" "redis" "media" "downloads"]) ++ ["d ${cfg.dataDir} 0755 root root - -" "d ${cfg.dataDir}/database 0755 root root - -" "d ${cfg.dataDir}/database/postgres 0755 root root - -"];
    networking.firewall.allowedTCPPorts = [cfg.port];
    virtualisation.oci-containers.containers.readmeabook = {
      inherit image;
      ports = ["${lan}:${toString cfg.port}:3030" "127.0.0.1:${toString cfg.port}:3030"];
      environmentFiles = [dbSecret];
      environment = {
        PUID = "2024";
        PGID = "2024";
        TZ = "Australia/Perth";
        PUBLIC_URL = "http://${lan}:${toString cfg.port}";
      };
      volumes = ["${cfg.dataDir}/config:/app/config" "${cfg.dataDir}/cache:/app/cache" "${cfg.dataDir}/redis:/var/lib/redis" "${cfg.dataDir}/media:/media" "${cfg.dataDir}/downloads:/downloads"];
      # Unified image remaps users, starts Redis, then drops the app to PUID.
      # PostgreSQL is external and isolated in its own nspawn container.
      extraOptions = config.homelab.podman.hardenOptions ++ ["--cap-add=CHOWN" "--cap-add=SETUID" "--cap-add=SETGID" "--cap-add=DAC_OVERRIDE" "--cap-add=FOWNER" "--cap-add=KILL" "--memory=2g" "--pids-limit=384"];
    };
    systemd.services.podman-readmeabook = {
      after = ["container@readmeabook-db.service"];
      requires = ["container@readmeabook-db.service"];
      restartTriggers = [config.systemd.units."container@readmeabook-db.service".unit dbSecret];
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-readmeabook.service";
        inherit image;
      }
    ];
    homelab.monitoring = {
      monitors = [
        {
          name = "ReadMeABook trial";
          url = "http://${lan}:${toString cfg.port}/api/health";
        }
      ];
      deepProbes = [
        {
          name = "ReadMeABook trial state";
          command = "${pkgs.callPackage ./probes/check-book-trial.nix {}}/bin/check-book-trial readmeabook ${cfg.dataDir} ${toString cfg.port}";
          interval = "5m";
          intervalSecs = 300;
          requiresUnit = ["podman-readmeabook.service"];
        }
      ];
      errorPatterns = [
        {
          name = "ReadMeABook database failure";
          unit = "podman-readmeabook.service";
          pattern = "PrismaClientInitializationError|Migrations may have failed|Server process .* exited unexpectedly";
          severity = "critical";
          summary = "ReadMeABook trial failed database or application startup";
          threshold = 0;
        }
      ];
    };
  };
}
