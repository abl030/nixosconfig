# Overseerr-like trial paired with Booklore and ABS. See book-platform-exploration.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.bookkeep;
  image = "docker.io/akiraslingshot/bookkeep:latest";
  lan = config.homelab.localProxy.localIp;
  dbSecret = config.sops.secrets.bookkeep-env.path;
  db = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "bookkeep";
    hostNum = 12;
    dataDir = "${cfg.dataDir}/database";
    passwordFile = dbSecret;
  };
in {
  options.homelab.services.bookkeep = {
    enable = lib.mkEnableOption "Bookkeep request-interface trial";
    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "bookkeep.ablz.au";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/bookkeep";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8788;
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.bookkeep.gid = 2023;
    users.users.bookkeep = {
      isSystemUser = true;
      uid = 2023;
      group = "bookkeep";
    };
    sops.secrets.bookkeep-env = {
      sopsFile = config.homelab.secrets.sopsFile "bookkeep.env";
      format = "dotenv";
      mode = "0400";
    };
    sops.secrets."book-trials/bootstrap" = {
      sopsFile = config.homelab.secrets.sopsFile "book-trials-bootstrap.json";
      format = "json";
      key = "";
      mode = "0400";
    };
    containers.bookkeep-db = db.containerConfig;
    systemd.tmpfiles.rules = (map (p: "d ${cfg.dataDir}/${p} 0750 bookkeep bookkeep - -") ["data" "downloads" "audiobooks" "ebooks"]) ++ ["d ${cfg.dataDir} 0755 root root - -" "d ${cfg.dataDir}/database 0755 root root - -" "d ${cfg.dataDir}/database/postgres 0755 root root - -"];
    networking.firewall.allowedTCPPorts = [cfg.port];
    virtualisation.oci-containers.containers.bookkeep = {
      inherit image;
      ports = ["${lan}:${toString cfg.port}:8000" "127.0.0.1:${toString cfg.port}:8000"];
      environmentFiles = [dbSecret];
      # libpq reads PGPASSWORD from the secret. Upstream logs DATABASE_URL,
      # so deliberately keep credentials out of this URI.
      environment = {
        DATABASE_URL = "postgresql://bookkeep@${db.dbHost}:5432/bookkeep";
        TZ = "Australia/Perth";
        HOME = "/app/data";
      };
      volumes = ["${cfg.dataDir}/data:/app/data" "${cfg.dataDir}/downloads:/downloads" "${cfg.dataDir}/audiobooks:/audiobooks" "${cfg.dataDir}/ebooks:/ebooks" "${./bookkeep-initialize.py}:/etc/bookkeep-initialize.py:ro"];
      # Fresh upstream image fails before ORM tables exist (upstream #89).
      # Existing databases continue through its normal migrations unchanged.
      cmd = ["/etc/bookkeep-initialize.py"];
      extraOptions = config.homelab.podman.hardenOptions ++ ["--entrypoint=python" "--user=2023:2023" "--memory=1536m" "--pids-limit=256"];
    };
    systemd.services.podman-bookkeep = {
      after = ["container@bookkeep-db.service"];
      requires = ["container@bookkeep-db.service"];
      restartTriggers = [config.systemd.units."container@bookkeep-db.service".unit dbSecret];
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-bookkeep.service";
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
    homelab.monitoring = {
      monitors = [
        {
          name = "Bookkeep trial";
          url = "https://${cfg.fqdn}/health";
        }
      ];
      deepProbes = [
        {
          name = "Bookkeep trial state";
          command = "${pkgs.callPackage ./probes/check-book-trial.nix {}}/bin/check-book-trial bookkeep ${cfg.dataDir} ${toString cfg.port}";
          interval = "5m";
          intervalSecs = 300;
          requiresUnit = ["podman-bookkeep.service"];
        }
      ];
      errorPatterns = [
        {
          name = "Bookkeep migration failure";
          unit = "podman-bookkeep.service";
          pattern = "Alembic migrations failed|NoSuchTableError|UndefinedTable";
          severity = "critical";
          summary = "Bookkeep trial database schema is unusable";
          threshold = 0;
        }
      ];
    };
  };
}
