# Outward 1 s pings from the Cullen site (wsl on Andy's laptop) for the WAN
# latency/loss record. Unprivileged ICMP sockets (ping_group_range is open), so
# no capabilities. See docs/wiki/services/cullen-wan-usage.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.cullenWanPing;
  source = builtins.path {
    path = ../../../scripts/cullen-wan-ping.py;
    name = "cullen-wan-ping.py";
  };
in {
  options.homelab.services.cullenWanPing = {
    enable = lib.mkEnableOption "Cullen outward ping logger";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cullen-wan-ping";
      description = "Daily per-target ping TSVs (gzipped after the day ends).";
    };
    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # LAN control (SonicWall X0), Fairtel gateway, Cloudflare, Google, Quad9, Telstra DNS (AU unicast).
      default = ["192.168.100.14" "205.164.127.1" "1.1.1.1" "8.8.8.8" "9.9.9.9" "139.130.4.5"];
      description = "Hosts pinged once a second.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.cullen-wan-ping = {};
    users.users.cullen-wan-ping = {
      isSystemUser = true;
      group = "cullen-wan-ping";
    };
    systemd.tmpfiles.rules = ["d ${cfg.dataDir} 0755 cullen-wan-ping cullen-wan-ping - -"];
    systemd.services.cullen-wan-ping = {
      description = "Log 1 s pings from the Cullen site";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        User = "cullen-wan-ping";
        Group = "cullen-wan-ping";
        UMask = "0022";
        ExecStart = "${pkgs.python3}/bin/python3 ${source} --data-dir ${lib.escapeShellArg cfg.dataDir} --ping ${pkgs.iputils}/bin/ping ${lib.escapeShellArgs cfg.targets}";
        Restart = "always";
        RestartSec = 10;
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
        ReadWritePaths = [cfg.dataDir];
        MemoryMax = "128M";
      };
    };
  };
}
