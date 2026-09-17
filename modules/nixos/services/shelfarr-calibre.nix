# Calibre GUI remains the only library writer; imports use its authenticated
# content server. See docs/wiki/services/shelfarr.md for tower setup/rollback.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.shelfarr;
  importer = builtins.path {
    path = ../../../scripts/shelfarr-calibre.py;
    name = "shelfarr-calibre.py";
  };
in {
  options.homelab.services.shelfarr.calibre.enable =
    lib.mkEnableOption "importing acquired Shelfarr ebooks into Calibre and scanning Komga";

  config = lib.mkIf (cfg.enable && cfg.calibre.enable) {
    sops.secrets."shelfarr/calibre-password" = {
      sopsFile = config.homelab.secrets.sopsFile "shelfarr-calibre.json";
      format = "json";
      key = "password";
    };
    users.groups.shelfarr-calibre = {};
    users.users.shelfarr-calibre = {
      isSystemUser = true;
      group = "shelfarr-calibre";
      extraGroups = ["shelfarr" "users"];
    };
    systemd.services.shelfarr-calibre = {
      description = "Import completed Shelfarr ebooks into Calibre";
      after = ["network-online.target" "podman-shelfarr.service"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = [cfg.ebookDir "${cfg.dataDir}/storage"];
      environment = {
        SHELFARR_DATABASE = "/mnt/shelfarr/production.sqlite3";
        EBOOK_ROOT = "/mnt/ebooks";
        CALIBREDB = "${pkgs.calibre}/bin/calibredb";
        CALIBRE_URL = "http://tower:8086/calibre/#Library";
        CALIBRE_USERNAME = "shelfarr";
        KOMGA_URL = "https://magazines.ablz.au";
        KOMGA_LIBRARY_ID = "0QFQQFTD08FRG";
        CALIBRE_CONFIG_DIRECTORY = "/var/lib/shelfarr-calibre/calibre";
        QT_QPA_PLATFORM = "offscreen";
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "shelfarr-calibre";
        Group = "shelfarr-calibre";
        ExecStart = "${pkgs.python3}/bin/python3 ${importer}";
        LoadCredential = [
          "calibre-password:${config.sops.secrets."shelfarr/calibre-password".path}"
          "komga-env:${config.sops.secrets."komga-sync/env".path}"
        ];
        StateDirectory = "shelfarr-calibre";
        StateDirectoryMode = "0700";
        UMask = "0077";
        TimeoutStartSec = "15min";
        MemoryMax = "1G";
        TasksMax = 64;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        TemporaryFileSystem = "/mnt";
        BindReadOnlyPaths = [
          "${cfg.ebookDir}:/mnt/ebooks"
          "${cfg.dataDir}/storage:/mnt/shelfarr"
        ];
        # SQLite needs its adjacent WAL/SHM. Hide the app's decryption keys;
        # this reader never gets a host control socket or library write mount.
        InaccessiblePaths = [
          "/mnt/shelfarr/.encryption_keys"
          "/mnt/shelfarr/.secret_key_base"
        ];
      };
    };
    systemd.timers.shelfarr-calibre = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = "1min";
      };
    };
    # Each timer run checks the source DB and authenticated remote library,
    # even with no pending books. Import/scan failures remain pending and log.
    homelab.monitoring.errorPatterns = [
      {
        name = "Shelfarr Calibre import failure";
        unit = "shelfarr-calibre.service";
        pattern = "SHELFARR_CALIBRE_FAILED";
        recoveryPattern = "Calibre bridge checked [0-9]+ acquired ebooks; 0 failed$";
        # One-minute retries must keep failing for five minutes. A fully
        # successful run clears pending/firing state on the next evaluation.
        # See docs/wiki/services/shelfarr.md for the 2026-09-17 restart incident.
        # Cover the 120s remote-command timeout plus the one-minute retry gap.
        window = "5m";
        threshold = 0;
        forDuration = "5m";
        severity = "warning";
        summary = "Shelfarr Calibre/Komga bridge has sustained failures";
        description = "Checks or delivery keep failing despite automatic retries. Brief Calibre restarts are suppressed; a complete successful run clears the condition.";
      }
    ];
  };
}
