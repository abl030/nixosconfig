# discogs.nix — Self-hosted Discogs data mirror
#
# Downloads monthly CC0 XML dumps from data.discogs.com, imports into
# PostgreSQL (nspawn container), serves a JSON API at discogs.ablz.au.
#
# Components:
#   container@discogs-db.service   — PostgreSQL 16 (nspawn, hostNum=6)
#   discogs-import.service         — oneshot: download + parse + COPY
#   discogs-import.timer           — 2nd of each month, 04:00
#   discogs-api.service            — long-running axum HTTP server
#
# Data lives on /mnt/mirrors/discogs — re-downloadable, NOT backed up.
#
# Operations: docs/wiki/services/discogs.md documents the cratedigger hold
# coupling and the /health readiness contract.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.homelab.services.discogs;

  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "discogs";
    hostNum = 6;
    dataDir = cfg.mirrorDir;
    passwordFile = "/run/secrets/discogs-pgpass";
  };

  discogsPkg = pkgs.rustPlatform.buildRustPackage {
    pname = "discogs-api";
    version = "0.1.0";
    src = inputs.discogs-src;
    cargoLock.lockFile = "${inputs.discogs-src}/Cargo.lock";
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
  };

  cratediggerGate = config.homelab.services.cratedigger.metadataGate;
  cratediggerGateEnabled = config.homelab.services.cratedigger.enable;
in {
  options.homelab.services.discogs = {
    enable = lib.mkEnableOption "Discogs data mirror";

    mirrorDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/mirrors/discogs";
      description = "Root directory for Discogs data (dumps + postgres). Re-downloadable, not backed up.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Port for the Discogs JSON API server.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [discogsPkg];

    # PG password — sops-managed dotenv with POSTGRES_PASSWORD; see #232.
    sops.secrets."discogs-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "discogs-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    # PostgreSQL nspawn container
    containers.discogs-db = pgc.containerConfig;

    systemd = {
      # Ensure data directories exist
      tmpfiles.rules = [
        "d ${cfg.mirrorDir} 0755 root root -"
        "d ${cfg.mirrorDir}/postgres 0700 root root -"
        "d ${cfg.mirrorDir}/dumps 0755 root root -"
      ];

      services = {
        # Importer — downloads latest XML dumps and loads into Postgres
        # Auto-retry on failure: importer is idempotent (drops + recreates tables),
        # so transient I/O glitches (e.g. virtiofs hiccup that crashes pg checkpoint
        # mid-load, observed 2026-05-02) self-heal instead of leaving the mirror
        # empty until the next monthly timer fires.
        discogs-import = {
          description = "Discogs dump importer";
          after = ["container@discogs-db.service" "network-online.target"];
          requires = ["container@discogs-db.service"];
          wants = ["network-online.target"];
          # Don't restart on nixos-rebuild — runs monthly via timer
          restartIfChanged = false;
          unitConfig = {
            StartLimitIntervalSec = "4h";
            StartLimitBurst = 4;
          };
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "3h";
            Restart = "on-failure";
            RestartSec = "15min";
            EnvironmentFile = config.sops.secrets."discogs-pgpass".path;
            # Wrap so $POSTGRES_PASSWORD expands at runtime — keeps the password
            # out of /nix/store, which the bare DSN string would otherwise leak.
            # Discogs imports drop/recreate mirror tables, so cratedigger must be
            # held before import work begins and resumed only after local health
            # and representative metadata probes pass.
            ExecStart = pkgs.writeShellScript "discogs-import-start" ''
              set -eu
              ${lib.optionalString cratediggerGateEnabled ''
                ${cratediggerGate.holdCommand} discogs-import
                cleanup_failed_import() {
                  if ${cratediggerGate.checkCommand}; then
                    ${cratediggerGate.releaseCommand} discogs-import
                    ${cratediggerGate.resumeIfClearCommand} || true
                  fi
                }
                trap cleanup_failed_import ERR
              ''}
              ${discogsPkg}/bin/discogs-import \
                --dsn "postgresql://discogs:$POSTGRES_PASSWORD@${pgc.dbHost}:${toString pgc.dbPort}/discogs" \
                --dump-dir '${cfg.mirrorDir}/dumps'
              ${lib.optionalString cratediggerGateEnabled ''
                trap - ERR
                ${cratediggerGate.releaseCommand} discogs-import
                ${cratediggerGate.resumeIfClearCommand} || true
              ''}
            '';
          };
        };

        # API server — long-running axum HTTP server
        # restartTriggers: see immich.nix comment — Requires= cascade-stops discogs-api
        # when the container restarts, and switch-to-configuration won't bring it back
        # unless the container's host-side unit derivation changed.
        discogs-api = {
          description = "Discogs mirror JSON API — discogs.ablz.au";
          after = ["container@discogs-db.service"];
          requires = ["container@discogs-db.service"];
          wantedBy = ["multi-user.target"];
          restartTriggers = [
            config.systemd.units."container@discogs-db.service".unit
            config.sops.secrets."discogs-pgpass".path
          ];
          serviceConfig = {
            Type = "simple";
            EnvironmentFile = config.sops.secrets."discogs-pgpass".path;
            ExecStart = pkgs.writeShellScript "discogs-api-start" ''
              set -eu
              exec ${discogsPkg}/bin/discogs-api \
                --dsn "postgresql://discogs:$POSTGRES_PASSWORD@${pgc.dbHost}:${toString pgc.dbPort}/discogs" \
                --port ${toString cfg.apiPort}
            '';
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };

      timers.discogs-import = {
        description = "Monthly Discogs dump import";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-02 04:00:00";
          Persistent = true;
        };
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "discogs.ablz.au";
          port = cfg.apiPort;
        }
      ];

      monitoring.monitors = [
        {
          name = "Discogs";
          type = "json-query";
          url = "https://discogs.ablz.au/health";
          # /health returns status="ok" only when releases > 0; status="awaiting_import"
          # when tables are empty (e.g. importer crashed mid-load and dropped tables).
          # Plain HTTP 200 is not enough — empty mirror still returns 200.
          jsonPath = "status";
          expectedValue = "ok";
        }
      ];
    };
  };
}
