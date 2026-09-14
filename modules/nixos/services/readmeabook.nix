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
  library = "/mnt/data/Media/Books/Audiobooks/ReadMeABook";
  torrents = "/mnt/data/Media/Temp/readmeabook";
  usenet = "/mnt/data/Media/Temp/completed/readmeabook";
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
    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "readmeabook.ablz.au";
    };
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
      extraGroups = ["users"];
    };
    sops.secrets.readmeabook-env = {
      sopsFile = config.homelab.secrets.sopsFile "readmeabook.env";
      format = "dotenv";
      mode = "0400";
    };
    containers.readmeabook-db = db.containerConfig;
    systemd.tmpfiles.rules =
      (map (p: "d ${cfg.dataDir}/${p} 0750 readmeabook readmeabook - -") ["config" "cache" "redis" "downloads"])
      ++ ["d ${cfg.dataDir} 0755 root root - -" "d ${cfg.dataDir}/database 0755 root root - -" "d ${cfg.dataDir}/database/postgres 0755 root root - -"]
      # Match the NAS all_squash identity without changing application UID.
      # The mixed-owner completed path is provisioned on tower; see the wiki.
      ++ map (p: "d ${p} 2775 99 users - -") [library torrents];
    networking.firewall.allowedTCPPorts = [cfg.port];
    virtualisation.oci-containers.containers.readmeabook = {
      inherit image;
      ports = ["${lan}:${toString cfg.port}:3030" "127.0.0.1:${toString cfg.port}:3030"];
      environmentFiles = [dbSecret];
      environment = {
        PUID = "2024";
        PGID = "100";
        TZ = "Australia/Perth";
        PUBLIC_URL = "https://${cfg.fqdn}";
      };
      volumes = [
        "${cfg.dataDir}/config:/app/config"
        "${cfg.dataDir}/cache:/app/cache"
        "${cfg.dataDir}/redis:/var/lib/redis"
        "${cfg.dataDir}/downloads:/downloads"
        "${library}:/media"
        # The tagger writes temporary siblings then copies to /media, preserving
        # seeding originals. Only this application's categories are writable.
        "${torrents}:/downloads/readmeabook"
        "${usenet}:/downloads/completed/readmeabook"
      ];
      # Unified image remaps users, starts Redis, then drops the app to PUID.
      # PostgreSQL is external and isolated in its own nspawn container.
      extraOptions = config.homelab.podman.hardenOptions ++ ["--cap-add=CHOWN" "--cap-add=SETUID" "--cap-add=SETGID" "--cap-add=DAC_OVERRIDE" "--cap-add=FOWNER" "--cap-add=KILL" "--memory=2g" "--pids-limit=384"];
    };
    systemd.services.podman-readmeabook = {
      after = ["container@readmeabook-db.service"];
      requires = ["container@readmeabook-db.service"];
      restartTriggers = [config.systemd.units."container@readmeabook-db.service".unit dbSecret];
      unitConfig.RequiresMountsFor = [cfg.dataDir library torrents usenet];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir library torrents usenet];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-readmeabook.service";
        inherit image;
      }
    ];
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
        websocket = true;
      }
    ];
    homelab.nfsWatchdog.podman-readmeabook.path = library;
    homelab.monitoring = {
      monitors = [
        {
          name = "ReadMeABook trial";
          url = "https://${cfg.fqdn}/api/health";
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
