# Cullen SonicWall per-port traffic counters (SNMP, 1/min) for monthly WAN usage.
# See docs/wiki/services/cullen-wan-usage.md for path, firewall side and queries.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.cullenWanUsage;
  source = builtins.path {
    path = ../../../scripts/cullen-wan-usage.py;
    name = "cullen-wan-usage.py";
  };
  command = "${pkgs.python3}/bin/python3 ${source}";
  dataArg = "--data-dir ${lib.escapeShellArg cfg.dataDir}";
  hardening = {
    Type = "oneshot";
    User = "cullen-wan-usage";
    Group = "cullen-wan-usage";
    # Byte counters only, no secrets: readable so the cullen-assistant reports can query it.
    UMask = "0022";
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
    TimeoutStartSec = "2min";
    MemoryMax = "128M";
  };
in {
  options.homelab.services.cullenWanUsage = {
    enable = lib.mkEnableOption "Cullen SonicWall WAN usage counters over SNMP";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cullen-wan-usage";
      description = "SQLite store of per-minute port counters.";
    };
    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Tech/Backups/CullenWanUsage";
      description = "Daily consistent copy inside the existing Kopia Life sources.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.cullen-wan-usage = {};
    users.users.cullen-wan-usage = {
      isSystemUser = true;
      group = "cullen-wan-usage";
    };
    # Read-only v2c community; the SonicWall only answers SNMP on X0 from the
    # "Andy laptop" group; doc1 arrives as the laptop because its Tailscale subnet route SNATs.
    sops.secrets."cullen-wan-usage/env" = {
      sopsFile = config.homelab.secrets.sopsFile "sonicwall-snmp.env";
      format = "dotenv";
      mode = "0400";
    };
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 cullen-wan-usage cullen-wan-usage - -"
      "d ${cfg.backupDir} 0755 cullen-wan-usage cullen-wan-usage - -"
    ];
    systemd.services.cullen-wan-usage = {
      description = "Sample Cullen SonicWall port counters over SNMP";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig =
        hardening
        // {
          LoadCredential = "snmp.env:${config.sops.secrets."cullen-wan-usage/env".path}";
          ExecStart = "${command} collect ${dataArg} --credential %d/snmp.env --snmpget ${lib.getBin pkgs.net-snmp}/bin/snmpget";
        };
    };
    systemd.timers.cullen-wan-usage = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "minutely";
        AccuracySec = "5s";
      };
    };
    systemd.services.cullen-wan-usage-backup = {
      description = "Copy Cullen WAN usage SQLite into the backed-up Life tree";
      unitConfig.RequiresMountsFor = [cfg.backupDir];
      serviceConfig =
        hardening
        // {
          PrivateNetwork = true;
          BindPaths = [cfg.backupDir];
          ExecStart = "${command} backup ${dataArg} --backup-dir ${lib.escapeShellArg cfg.backupDir}";
        };
    };
    systemd.timers.cullen-wan-usage-backup = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 03:40:00";
        Persistent = true;
      };
    };
    # The path depends on Andy's laptop being on site, so short gaps are normal;
    # counters are cumulative, so a gap loses resolution, not bytes. Warn after a day.
    homelab.monitoring.deepProbes = [
      {
        name = "Cullen WAN usage collection";
        command = "${command} check ${dataArg} --max-age 86400";
        interval = "1h";
        intervalSecs = 4500;
        serviceConfig.ReadOnlyPaths = [cfg.dataDir];
      }
    ];
    # First activation must take a sample before the probe looks for one.
    systemd.services.deep-probe-cullen-wan-usage-collection.after = ["cullen-wan-usage.service"];
    systemd.services.post-maintenance-deep-probe-cullen-wan-usage-collection.after = ["cullen-wan-usage.service"];
  };
}
