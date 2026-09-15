# Fine-grained HA history with independent collection/backup failure domains.
# See docs/wiki/services/winery-history.md for format, recovery and HA identity.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.wineryHistory;
  source = builtins.path {
    path = ../../../scripts/winery-history.py;
    name = "winery-history.py";
  };
  command = "${pkgs.python3}/bin/python3 ${source}";
  dataArg = "--data-dir ${lib.escapeShellArg cfg.dataDir}";
  hardening = {
    Type = "oneshot";
    User = "winery-history";
    Group = "winery-history";
    UMask = "0027";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
    TemporaryFileSystem = "/mnt";
    ReadWritePaths = [cfg.dataDir];
    TimeoutStartSec = "10min";
    MemoryMax = "256M";
  };
in {
  options.homelab.services.wineryHistory = {
    enable = lib.mkEnableOption "durable hot-water and solar history archive";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/winery-history";
      description = "Local archive and atomic capture/backup checkpoints.";
    };
    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Tech/Backups/WineryHotWater";
      description = "Narrow backup destination inside the existing Kopia Life sources.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://home.ablz.au";
      description = "Home Assistant HTTPS origin.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.winery-history = {};
    users.users.winery-history = {
      isSystemUser = true;
      group = "winery-history";
    };
    sops.secrets."winery-history/env" = {
      sopsFile = config.homelab.secrets.sopsFile "winery-history.env";
      format = "dotenv";
      mode = "0400";
    };
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 winery-history winery-history - -"
      # Readable by the unprivileged Kopia LXC; contains sensor history, no secrets.
      "d ${cfg.backupDir} 0755 winery-history winery-history - -"
    ];
    systemd.services.winery-history = {
      description = "Archive original winery hot-water and PV history from HA";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      unitConfig.OnSuccess = "winery-history-backup.service";
      serviceConfig =
        hardening
        // {
          LoadCredential = "ha.env:${config.sops.secrets."winery-history/env".path}";
          ExecStart = "${command} collect ${dataArg} --url ${lib.escapeShellArg cfg.url} --credential %d/ha.env";
        };
    };
    systemd.timers.winery-history = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* *:15:00";
        Persistent = true;
        RandomizedDelaySec = "2m";
      };
    };
    systemd.services.winery-history-backup = {
      description = "Copy and verify immutable winery history into the backed-up Life tree";
      unitConfig.RequiresMountsFor = [cfg.backupDir];
      serviceConfig =
        hardening
        // {
          # No HA credential or client network access in the file-copy unit.
          PrivateNetwork = true;
          BindPaths = [cfg.backupDir];
          ExecStart = "${command} backup ${dataArg} --backup-dir ${lib.escapeShellArg cfg.backupDir}";
        };
    };
    systemd.timers.winery-history-backup = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* *:35:00";
        Persistent = true;
      };
    };
    # A timer being active is insufficient: inspect saved progress, a real
    # gzip chunk and its checksum, and the independently verified backup cursor.
    homelab.monitoring.deepProbes = [
      {
        name = "Winery history archive and backup";
        command = "${command} check ${dataArg}";
        interval = "30m";
        intervalSecs = 2100;
        serviceConfig.ReadOnlyPaths = [cfg.dataDir];
      }
    ];
    homelab.monitoring.errorPatterns = [
      {
        name = "Winery history capture failed";
        unit = "winery-history.service";
        pattern = "WINERY_HISTORY_FAILED|WINERY_HISTORY_GAP";
        threshold = 0;
        severity = "warning";
        summary = "Winery history archive failed or exceeded its recovery window";
        description = "Inspect winery-history.service and /var/lib/winery-history/capture.json before HA raw-history retention expires.";
      }
      {
        name = "Winery history backup failed";
        unit = "winery-history-backup.service";
        pattern = "WINERY_HISTORY_FAILED";
        threshold = 0;
        severity = "warning";
        summary = "Winery history copy or checksum verification failed";
        description = "Collection continues locally. Inspect winery-history-backup.service and its backup destination.";
      }
    ];
    # No listening socket/proxy. Independent retry timer handles the NFS copy;
    # an NFS watchdog must not restart the unrelated local collection unit.
  };
}
