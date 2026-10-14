# Cullen SonicWall per-port counters over SNMP (10 s): WAN usage, throughput and link flaps.
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
      description = "SQLite store of 10 s port counters (thinned to 1/min after 35 days).";
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
    # Long-running 10 s poller: the 10 s counters line up throughput with the
    # latency probes on wsl, and ifLastChange catches 2-4 s link flaps between polls.
    systemd.services.cullen-wan-usage = {
      description = "Poll Cullen SonicWall port counters over SNMP every 10 s";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig =
        hardening
        // {
          Type = "simple";
          Restart = "always";
          RestartSec = 30;
          LoadCredential = "snmp.env:${config.sops.secrets."cullen-wan-usage/env".path}";
          ExecStart = "${command} run ${dataArg} --interval 10 --credential %d/snmp.env --snmpget ${lib.getBin pkgs.net-snmp}/bin/snmpget";
        };
    };
    systemd.services.cullen-wan-usage-backup = {
      description = "Thin old 10 s Cullen WAN samples to 1/min and copy SQLite into the backed-up Life tree";
      unitConfig.RequiresMountsFor = [cfg.backupDir];
      serviceConfig =
        hardening
        // {
          PrivateNetwork = true;
          BindPaths = [cfg.backupDir];
          ExecStart = "${command} backup ${dataArg} --keep-days 35 --interval 10 --backup-dir ${lib.escapeShellArg cfg.backupDir}";
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
