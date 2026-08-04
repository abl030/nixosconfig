{
  config,
  hostConfig,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.ci.cratedigger12hReport;
  reporter = pkgs.writers.writePython3Bin "cratedigger-12h-report" {} (
    builtins.readFile ./scripts/cratedigger_12h_report.py
  );
  reportSkill = pkgs.writeText "cratedigger-report-skill.md" (
    builtins.readFile ../../../hermes/skills/homelab-agents/cratedigger-report/SKILL.md
  );
  reportAgent = pkgs.writeText "cratedigger-report-agent.py" (
    builtins.readFile ./scripts/cratedigger_report_agent.py
  );
  userHome = config.users.users.${hostConfig.user}.home;
in {
  options.homelab.ci.cratedigger12hReport = {
    enable = lib.mkEnableOption "exact 12-hour Cratedigger Loki reports analyzed by Hermes";

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://loki.ablz.au";
      description = "Loki base URL queried for Cratedigger journal streams.";
    };

    reportTarget = lib.mkOption {
      type = lib.types.str;
      default = "ntfy";
      description = "Hermes send target for non-empty failure digests.";
    };

    notificationEnvironmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing credentials for the Hermes send target.";
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone;
      description = "Timezone whose midnight and noon delimit exact report windows.";
    };

    maxBackfillWindows = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Maximum closed 12-hour windows completed by one invocation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.notificationEnvironmentFile != null;
        message = "cratedigger12hReport.notificationEnvironmentFile is required";
      }
    ];

    systemd.services.cratedigger-12h-report = {
      description = "Analyze a closed 12-hour Cratedigger Loki window";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      startLimitIntervalSec = 1800;
      startLimitBurst = 3;

      environment = {
        HOME = userHome;
        HERMES_BIN = lib.getExe pkgs.hermes-agent;
        HERMES_PYTHON = "${pkgs.hermes-agent.passthru.hermesVenv}/bin/python3";
        LOKI_URL = cfg.lokiUrl;
        REPORT_AGENT = reportAgent;
        REPORT_TARGET = cfg.reportTarget;
        REPORT_SKILL_FILE = reportSkill;
        REPORT_TIMEZONE = cfg.timeZone;
        STATE_FILE = "/var/lib/cratedigger-12h-report/last-end";
        MAX_BACKFILL_WINDOWS = toString cfg.maxBackfillWindows;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe reporter;
        EnvironmentFile = cfg.notificationEnvironmentFile;
        User = hostConfig.user;
        Group = "users";
        StateDirectory = "cratedigger-12h-report";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/cratedigger-12h-report";
        Restart = "on-failure";
        RestartSec = "5min";
        RuntimeMaxSec = "3h";

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = "read-only";
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ReadWritePaths = ["${userHome}/.hermes"];
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
        UMask = "0077";
      };
    };

    systemd.timers.cratedigger-12h-report = {
      description = "Twice-daily Cratedigger log-report trigger";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = ["*-*-* 00:10:00" "*-*-* 12:10:00"];
        Persistent = true;
        AccuracySec = "1min";
        Unit = "cratedigger-12h-report.service";
      };
    };
  };
}
