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
    inherit lib pkgs;
    name = "discogs";
    hostNum = 6;
    dataDir = cfg.databaseDir;
    passwordFile = "/run/secrets/discogs-pgpass";
    native = cfg.databaseMode == "native";
  };
  nativeDatabase = cfg.databaseMode == "native";
  dbUnit =
    if nativeDatabase
    then "postgresql.service"
    else "container@discogs-db.service";

  discogsPkg = pkgs.rustPlatform.buildRustPackage {
    pname = "discogs-api";
    version = "0.1.0";
    src = inputs.discogs-src;
    cargoLock.lockFile = "${inputs.discogs-src}/Cargo.lock";
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.postgresql_16
    ];
    buildInputs = [pkgs.openssl];
  };
in {
  options.homelab.services.discogs = {
    enable = lib.mkEnableOption "Discogs data mirror";

    mirrorDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/mirrors/discogs";
      description = "Root directory for Discogs data (dumps + postgres). Re-downloadable, not backed up.";
    };

    databaseDir = lib.mkOption {
      type = lib.types.str;
      default = cfg.mirrorDir;
      description = "Root containing the PostgreSQL data directory; may be a dedicated direct-bound dataset.";
    };

    databaseMode = lib.mkOption {
      type = lib.types.enum ["nspawn" "native"];
      default = "nspawn";
      description = "Run PostgreSQL in nspawn, or natively when this service owns a dedicated LXC appliance.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Port for the Discogs JSON API server.";
    };

    publish = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Publish discogs.ablz.au and its external monitor. Disable while staging a parallel canary.";
    };

    importCoordinator = lib.mkOption {
      type = lib.types.enum ["local" "remote"];
      default = "local";
      description = "Run the monthly import timer locally, or leave scheduling and retry/metadata-gate coordination to Cratedigger on another host.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf nativeDatabase pgc.nativeConfig)
    {
      environment.systemPackages = [discogsPkg];

      # PG password — sops-managed dotenv with POSTGRES_PASSWORD; see #232.
      sops.secrets."discogs-pgpass" = {
        sopsFile = config.homelab.secrets.sopsFile "discogs-pgpass.env";
        format = "dotenv";
        mode = "0400";
      };

      # PostgreSQL nspawn container, retained for ordinary multi-service hosts.
      containers.discogs-db = lib.mkIf (!nativeDatabase) pgc.containerConfig;

      # The JSON API is a LAN consumer surface as well as the local reverse
      # proxy's upstream. Keep it reachable for Cratedigger and direct canary
      # probes regardless of whether the public proxy/monitor is published.
      networking.firewall.allowedTCPPorts = [cfg.apiPort];

      systemd = {
        # Ensure data directories exist
        tmpfiles.rules = [
          "d ${cfg.mirrorDir} 0755 root root -"
          "d ${cfg.mirrorDir}/dumps 0755 root root -"
          "d ${cfg.databaseDir} 0755 root root -"
          "d ${cfg.databaseDir}/postgres 0700 ${
            if nativeDatabase
            then "postgres postgres"
            else "root root"
          } -"
        ];

        services = {
          postgresql = lib.mkIf nativeDatabase {
            unitConfig.RequiresMountsFor = [cfg.databaseDir];
          };

          # Importer — downloads latest XML dumps and loads into Postgres
          # Auto-retry on failure: importer is idempotent (drops + recreates tables),
          # so transient I/O glitches (e.g. virtiofs hiccup that crashes pg checkpoint
          # mid-load, observed 2026-05-02) self-heal instead of leaving the mirror
          # empty until the next monthly timer fires.
          discogs-import = {
            description = "Discogs dump importer";
            after = [dbUnit "network-online.target"];
            requires = [dbUnit];
            wants = ["network-online.target"];
            # Don't restart on nixos-rebuild — runs monthly via timer
            restartIfChanged = false;
            unitConfig = {
              StartLimitIntervalSec = "4h";
              StartLimitBurst = 4;
              # #257: fail-loud mirror bind ordered after mnt-mirrors.mount.
              RequiresMountsFor = [cfg.mirrorDir];
            };
            serviceConfig = {
              Type = "oneshot";
              NoNewPrivileges = true; # discogs-import binary; no setuid exec (#232)
              TimeoutStartSec = "3h";
              Restart =
                if cfg.importCoordinator == "local"
                then "on-failure"
                else "no";
              RestartSec = "15min";
              EnvironmentFile = config.sops.secrets."discogs-pgpass".path;
              # #257: blank /mnt, bind back only the mirror dir this importer
              # downloads dumps into. Was: full /mnt/* RW as root.
              TemporaryFileSystem = "/mnt";
              BindPaths = [cfg.mirrorDir];
              # Wrap so $POSTGRES_PASSWORD expands at runtime — keeps the password
              # out of /nix/store, which the bare DSN string would otherwise leak.
              ExecStart = pkgs.writeShellScript "discogs-import-start" ''
                set -eu
                ${discogsPkg}/bin/discogs-import \
                  --dsn "postgresql://discogs:$POSTGRES_PASSWORD@${pgc.dbHost}:${toString pgc.dbPort}/discogs" \
                  --dump-dir '${cfg.mirrorDir}/dumps'
              '';
            };
          };

          # API server — long-running axum HTTP server
          # restartTriggers: see immich.nix comment — Requires= cascade-stops discogs-api
          # when the container restarts, and switch-to-configuration won't bring it back
          # unless the container's host-side unit derivation changed.
          discogs-api = {
            description = "Discogs mirror JSON API — discogs.ablz.au";
            after = [dbUnit];
            requires = [dbUnit];
            wantedBy = ["multi-user.target"];
            restartTriggers = [
              config.systemd.units.${dbUnit}.unit
              config.sops.secrets."discogs-pgpass".path
            ];
            serviceConfig = {
              Type = "simple";
              NoNewPrivileges = true; # discogs axum API binary; no setuid exec (#232)
              EnvironmentFile = config.sops.secrets."discogs-pgpass".path;
              ExecStart = pkgs.writeShellScript "discogs-api-start" ''
                set -eu
                exec ${discogsPkg}/bin/discogs-api \
                  --dsn "postgresql://discogs:$POSTGRES_PASSWORD@${pgc.dbHost}:${toString pgc.dbPort}/discogs" \
                  --port ${toString cfg.apiPort}
              '';
              Restart = "on-failure";
              RestartSec = 5;
              # #257: this API server is stateless (talks to the discogs-db
              # nspawn container over TCP) and ran as root with the full /mnt/*
              # tree RW. Harden it: ProtectSystem=strict + blank /mnt, nothing
              # bound back. No NAMESPACE errorPattern — no bind source to fail.
              ProtectSystem = "strict";
              TemporaryFileSystem = "/mnt";
            };
          };
        };

        timers.discogs-import = {
          description = "Monthly Discogs dump import";
          wantedBy = lib.optionals (cfg.importCoordinator == "local") ["timers.target"];
          timerConfig = {
            OnCalendar = "*-*-02 04:00:00";
            Persistent = true;
          };
        };
      };

      homelab = {
        localProxy.hosts = lib.optionals cfg.publish [
          {
            host = "discogs.ablz.au";
            port = cfg.apiPort;
          }
        ];

        monitoring.monitors = lib.optionals cfg.publish [
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

        # See #253 audit + rules-doc "Per-service errorPatterns".
        monitoring.errorPatterns = [
          {
            name = "Discogs API DB error";
            unit = "discogs-api.service";
            # "Connection error: connection closed" alone is transient
            # WARN noise — excluded. Real failure = repeated db error
            # from migrations / schema-side, or post-#232 pgauth class.
            pattern = "(?i)Error occurred while creating a new object: db error|password authentication failed for user \"discogs\"";
            severity = "critical";
            summary = "discogs-api can't talk to its DB";
          }
        ];
      };
    }
  ]);
}
