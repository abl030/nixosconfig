# Soularr — homelab wrapper around the upstream module.
# =====================================================
#
# The actual NixOS module lives in the soularr repo at nix/module.nix and is
# consumed via inputs.soularr-src.nixosModules.default. This wrapper supplies
# the homelab-specific bits the upstream module deliberately doesn't know
# about:
#
#   - sops-nix per-key secret extraction (slskd API key, notifier creds)
#   - the nspawn PostgreSQL container backing the pipeline DB
#   - the redis instance that the web UI's cache uses
#   - the localProxy entry that puts the web UI behind music.ablz.au
#   - systemd ordering against container@soularr-db.service
#
# Tuning notes that used to live in the giant downstream module now live in
# the upstream module's option docs (or in the soularr README for quality
# rank tuning). Anything past the option-set below is purely homelab plumbing.
#
# Network topology (unchanged from the legacy module):
#   doc2 has two NICs on 192.168.1.0/24:
#     ens18 = 192.168.1.35 (main, DHCP) — Lidarr, soularr, NFS, everything else
#     ens19 = 192.168.1.36 (VPN, static) — slskd Soulseek traffic only
#   See slskd.nix for the policy routing.
#
# Debugging:
#   journalctl -u soularr -f              — watch a run in real time
#   sudo systemctl start soularr          — trigger a run now
#   sudo cat /var/lib/soularr/config.ini  — verify rendered config
#   curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>' | jq
#                                         — check slskd search queue
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.homelab.services.soularr;

  # PostgreSQL in an nspawn container — data lives at cfg.dataDir/postgres
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "soularr";
    hostNum = 5;
    dataDir = cfg.dataDir;
  };

  sopsFile = config.homelab.secrets.sopsFile "soularr.env";
in {
  imports = [inputs.soularr-src.nixosModules.default];

  options.homelab.services.soularr = {
    enable = lib.mkEnableOption "Soularr — Soulseek download pipeline (homelab wrapper)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/soularr";
      description = "Directory for all Soularr state (contains postgres subdirectory).";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Download directory for slskd.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ---------------------------------------------------------------------
    # sops-nix: extract each individual secret from soularr.env.
    # The upstream module wants per-key file paths, not a multi-key envfile.
    # ---------------------------------------------------------------------
    sops.secrets = {
      "soularr/slskd-api-key" = {
        inherit sopsFile;
        format = "dotenv";
        key = "SOULARR_SLSKD_API_KEY";
        owner = "root";
        mode = "0400";
      };
      "soularr/meelo-username" = {
        inherit sopsFile;
        format = "dotenv";
        key = "MEELO_USERNAME";
        owner = "root";
        mode = "0400";
      };
      "soularr/meelo-password" = {
        inherit sopsFile;
        format = "dotenv";
        key = "MEELO_PASSWORD";
        owner = "root";
        mode = "0400";
      };
      "soularr/plex-token" = {
        inherit sopsFile;
        format = "dotenv";
        key = "PLEX_TOKEN";
        owner = "root";
        mode = "0400";
      };
      "soularr/jellyfin-token" = {
        inherit sopsFile;
        format = "dotenv";
        key = "JELLYFIN_TOKEN";
        owner = "root";
        mode = "0400";
      };
    };

    # ---------------------------------------------------------------------
    # PostgreSQL container — pipeline DB.
    # ---------------------------------------------------------------------
    containers.soularr-db = pgc.containerConfig;

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/postgres 0700 root root -"
    ];

    # ---------------------------------------------------------------------
    # Redis cache for the web UI (in-memory only, no persistence).
    # ---------------------------------------------------------------------
    services.redis.servers.soularr = {
      enable = true;
      port = 6379;
      save = []; # no persistence — pure cache
    };

    # ---------------------------------------------------------------------
    # Reverse proxy entry.
    # ---------------------------------------------------------------------
    homelab.localProxy.hosts = [
      {
        host = "music.ablz.au";
        port = config.services.soularr.web.port;
      }
    ];

    # ---------------------------------------------------------------------
    # Wire up the upstream module.
    # ---------------------------------------------------------------------
    services.soularr = {
      enable = true;

      slskd = {
        apiKeyFile = config.sops.secrets."soularr/slskd-api-key".path;
        downloadDir = cfg.downloadDir;
      };

      pipelineDb.dsn = pgc.dbUri;

      beetsValidation = {
        enable = true;
        stagingDir = "/mnt/virtio/Music/Incoming";
        trackingFile = "/mnt/virtio/Music/Re-download/beets-validated.jsonl";
      };

      web = {
        enable = true;
        beetsDb = "/mnt/virtio/Music/beets-library.db";
        redis.host = "127.0.0.1";
      };

      notifiers = {
        meelo = {
          enable = true;
          url = "https://meelo.ablz.au";
          usernameFile = config.sops.secrets."soularr/meelo-username".path;
          passwordFile = config.sops.secrets."soularr/meelo-password".path;
        };
        plex = {
          enable = true;
          url = "https://plex.ablz.au";
          tokenFile = config.sops.secrets."soularr/plex-token".path;
          librarySectionId = 3;
          pathMap = "/mnt/virtio/Music/Beets:/prom_music";
        };
        jellyfin = {
          enable = true;
          url = "https://jelly.ablz.au";
          tokenFile = config.sops.secrets."soularr/jellyfin-token".path;
        };
      };

      healthCheck = {
        enable = true;
        onFailureCommand = "${pkgs.systemd}/bin/systemctl restart slskd.service";
      };
    };

    # ---------------------------------------------------------------------
    # Homelab-specific systemd ordering against the nspawn DB container.
    # The upstream module already sets the cross-unit deps among the soularr
    # services themselves; we just splice in container@soularr-db.service.
    # restartTriggers ensure switch-to-configuration re-runs the migrate
    # oneshot whenever the container derivation changes.
    # ---------------------------------------------------------------------
    systemd.services.soularr-db-migrate = {
      after = ["container@soularr-db.service"];
      requires = ["container@soularr-db.service"];
      restartTriggers = [config.systemd.units."container@soularr-db.service".unit];
    };

    systemd.services.soularr = {
      after = ["slskd.service" "container@soularr-db.service"];
      wants = ["slskd.service" "container@soularr-db.service"];
    };

    systemd.services.soularr-web = {
      after = ["container@soularr-db.service" "redis-soularr.service"];
      wants = ["container@soularr-db.service" "redis-soularr.service"];
      restartTriggers = [config.systemd.units."container@soularr-db.service".unit];
    };
  };
}
