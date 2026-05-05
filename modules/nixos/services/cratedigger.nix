# Cratedigger — homelab wrapper around the upstream module.
# =====================================================
#
# The actual NixOS module lives in the cratedigger repo at nix/module.nix and is
# consumed via inputs.cratedigger-src.nixosModules.default. This wrapper supplies
# the homelab-specific bits the upstream module deliberately doesn't know
# about:
#
#   - sops-nix per-key secret extraction (slskd API key, notifier creds)
#   - the nspawn PostgreSQL container backing the pipeline DB
#   - the localProxy entry that puts the web UI behind music.ablz.au
#   - systemd ordering against container@cratedigger-db.service
#
# Tuning notes that used to live in the giant downstream module now live in
# the upstream module's option docs (or in the cratedigger README for quality
# rank tuning). Anything past the option-set below is purely homelab plumbing.
#
# Network topology (unchanged from the legacy module):
#   doc2 has two NICs on 192.168.1.0/24:
#     ens18 = 192.168.1.35 (main, DHCP) — Lidarr, cratedigger, NFS, everything else
#     ens19 = 192.168.1.36 (VPN, static) — slskd Soulseek traffic only
#   See slskd.nix for the policy routing.
#
# Debugging:
#   journalctl -u cratedigger -f              — watch a run in real time
#   sudo systemctl start cratedigger          — trigger a run now
#   sudo cat /var/lib/cratedigger/config.ini  — verify rendered config
#   curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>' | jq
#                                         — check slskd search queue
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.homelab.services.cratedigger;

  # PostgreSQL in an nspawn container — data lives at cfg.dataDir/postgres
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "cratedigger";
    hostNum = 5;
    dataDir = cfg.dataDir;
  };

  sopsFile = config.homelab.secrets.sopsFile "soularr.env";
in {
  imports = [inputs.cratedigger-src.nixosModules.default];

  options.homelab.services.cratedigger = {
    enable = lib.mkEnableOption "Cratedigger — Soulseek download pipeline (homelab wrapper)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/cratedigger";
      description = "Directory for all Cratedigger state (contains postgres subdirectory).";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Download directory for slskd.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ---------------------------------------------------------------------
    # sops-nix: decrypt the dotenv-format envfile, then split it into
    # per-key files that the upstream module can consume.
    #
    # NOTE: sops-nix `key = "X"` extraction does NOT work for multi-key
    # dotenv files — it writes the whole `KEY=VALUE` envfile regardless
    # (verified on doc2; same gotcha is documented in alerting.nix for
    # the gotify token). The upstream module wants raw values per file,
    # so we materialize them via a oneshot at boot.
    # ---------------------------------------------------------------------
    sops.secrets."soularr/env" = {
      inherit sopsFile;
      format = "dotenv";
      owner = "root";
      mode = "0400";
    };

    systemd.services.cratedigger-secrets-split = {
      description = "Split soularr.env into per-key secret files for the upstream module";
      wantedBy = ["multi-user.target"];
      before = [
        "cratedigger.service"
        "cratedigger-web.service"
        "cratedigger-db-migrate.service"
        "cratedigger-importer.service"
        "cratedigger-import-preview-worker.service"
      ];
      after = ["sysinit-reactivation.target"];
      restartTriggers = [config.sops.secrets."soularr/env".path];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cratedigger-secrets-split" ''
          set -euo pipefail
          env_file="${config.sops.secrets."soularr/env".path}"
          out_dir="/run/cratedigger-secrets"
          # Dir is 0750 root:users + files are 0440 root:users so operators
          # in the `users` group (notably abl030) can read the raw secrets
          # when running `pipeline-cli force-import` from a non-root shell.
          # Without this, post-import Meelo/Plex/Jellyfin notifier scans from
          # CLI invocations silently no-op — the upstream module doesn't copy
          # plaintext into config.ini anymore (issue #117), so the operator
          # has to read the source files directly.
          ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g users "$out_dir"
          for key in SOULARR_SLSKD_API_KEY MEELO_USERNAME MEELO_PASSWORD PLEX_TOKEN JELLYFIN_TOKEN; do
            ${pkgs.gnugrep}/bin/grep -m1 "^$key=" "$env_file" \
              | ${pkgs.coreutils}/bin/cut -d= -f2- \
              | ${pkgs.coreutils}/bin/tr -d '\n' \
              > "$out_dir/$key"
            ${pkgs.coreutils}/bin/chmod 0440 "$out_dir/$key"
            ${pkgs.coreutils}/bin/chgrp users "$out_dir/$key"
          done
        '';
      };
    };

    # ---------------------------------------------------------------------
    # PostgreSQL container — pipeline DB.
    # ---------------------------------------------------------------------
    containers.cratedigger-db = pgc.containerConfig;

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/postgres 0700 root root -"
    ];

    # ---------------------------------------------------------------------
    # Reverse proxy entry.
    # ---------------------------------------------------------------------
    homelab.localProxy.hosts = [
      {
        host = "music.ablz.au";
        port = config.services.cratedigger.web.port;
      }
    ];

    # ---------------------------------------------------------------------
    # Wire up the upstream module.
    # ---------------------------------------------------------------------
    services.cratedigger = {
      enable = true;

      # config.ini is world-readable (0644) since issue #117 — it contains
      # only *_file paths, no secrets. The raw secrets live under
      # /run/cratedigger-secrets (group-readable by `users`, see the splitter
      # above) and the Python pipeline reads them on demand via
      # CratediggerConfig.resolved_*() accessors.

      slskd = {
        apiKeyFile = "/run/cratedigger-secrets/SOULARR_SLSKD_API_KEY";
        downloadDir = cfg.downloadDir;
      };

      pipelineDb.dsn = pgc.dbUri;
      importer.preview.enable = true;

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
          usernameFile = "/run/cratedigger-secrets/MEELO_USERNAME";
          passwordFile = "/run/cratedigger-secrets/MEELO_PASSWORD";
        };
        plex = {
          enable = true;
          url = "https://plex.ablz.au";
          tokenFile = "/run/cratedigger-secrets/PLEX_TOKEN";
          librarySectionId = 3;
          pathMap = "/mnt/virtio/Music/Beets:/prom_music";
        };
        jellyfin = {
          enable = true;
          url = "https://jelly.ablz.au";
          tokenFile = "/run/cratedigger-secrets/JELLYFIN_TOKEN";
        };
      };

      healthCheck = {
        enable = true;
        onFailureCommand = "${pkgs.systemd}/bin/systemctl restart slskd.service";
      };
    };

    # ---------------------------------------------------------------------
    # Homelab-specific systemd ordering against the nspawn DB container.
    # The upstream module already sets the cross-unit deps among the cratedigger
    # services themselves; we just splice in container@cratedigger-db.service.
    # restartTriggers ensure switch-to-configuration re-runs the migrate
    # oneshot whenever the container derivation changes.
    # ---------------------------------------------------------------------
    systemd.services.cratedigger-db-migrate = {
      after = ["container@cratedigger-db.service"];
      requires = ["container@cratedigger-db.service"];
      restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
    };

    systemd.services.cratedigger = {
      after = ["slskd.service" "container@cratedigger-db.service"];
      wants = ["slskd.service" "container@cratedigger-db.service"];
    };

    systemd.services.cratedigger-web = {
      after = ["container@cratedigger-db.service" "redis-cratedigger.service"];
      wants = ["container@cratedigger-db.service" "redis-cratedigger.service"];
      restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
    };
  };
}
