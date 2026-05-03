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
  };

  discogsPkg = pkgs.rustPlatform.buildRustPackage {
    pname = "discogs-api";
    version = "0.1.0";
    src = inputs.discogs-src;
    cargoLock.lockFile = "${inputs.discogs-src}/Cargo.lock";
    nativeBuildInputs = [pkgs.pkg-config];
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

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Port for the Discogs JSON API server.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [discogsPkg];

    # PostgreSQL nspawn container
    containers.discogs-db = pgc.containerConfig;

    # Ensure data directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.mirrorDir} 0755 root root -"
      "d ${cfg.mirrorDir}/postgres 0700 root root -"
      "d ${cfg.mirrorDir}/dumps 0755 root root -"
    ];

    # Importer — downloads latest XML dumps and loads into Postgres
    # Auto-retry on failure: importer is idempotent (drops + recreates tables),
    # so transient I/O glitches (e.g. virtiofs hiccup that crashes pg checkpoint
    # mid-load, observed 2026-05-02) self-heal instead of leaving the mirror
    # empty until the next monthly timer fires.
    systemd.services.discogs-import = {
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
        ExecStart = "${discogsPkg}/bin/discogs-import --dsn '${pgc.dbUri}' --dump-dir '${cfg.mirrorDir}/dumps'";
      };
    };

    systemd.timers.discogs-import = {
      description = "Monthly Discogs dump import";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-02 04:00:00";
        Persistent = true;
      };
    };

    # API server — long-running axum HTTP server
    # restartTriggers: see immich.nix comment — Requires= cascade-stops discogs-api
    # when the container restarts, and switch-to-configuration won't bring it back
    # unless the container's host-side unit derivation changed.
    systemd.services.discogs-api = {
      description = "Discogs mirror JSON API — discogs.ablz.au";
      after = ["container@discogs-db.service"];
      requires = ["container@discogs-db.service"];
      wantedBy = ["multi-user.target"];
      restartTriggers = [config.systemd.units."container@discogs-db.service".unit];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${discogsPkg}/bin/discogs-api --dsn '${pgc.dbUri}' --port ${toString cfg.apiPort}";
        Restart = "on-failure";
        RestartSec = 5;
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
