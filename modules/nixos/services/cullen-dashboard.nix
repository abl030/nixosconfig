{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.cullen-dashboard;

  metadataDir = "${pkgs.vinsight-local}/share/vinsight-local/spec/metadata";
  dbPath = "${cfg.stateDir}/vinsight.db";
  vinsight = "${pkgs.vinsight-local}/bin/vinsight-sync";

  baseArgs = "--db ${dbPath} --metadata ${metadataDir}";

  seedScript = pkgs.writeShellScript "cullen-dashboard-seed" ''
    set -euo pipefail
    if [[ ! -s ${dbPath} ]]; then
      echo "cullen-dashboard: seeding Vinsight mirror at ${dbPath}"
      ${vinsight} ${baseArgs} init
      ${vinsight} ${baseArgs} run --full
    else
      echo "cullen-dashboard: ${dbPath} already exists, skipping seed"
    fi
  '';
in {
  options.homelab.services.cullen-dashboard = {
    enable = lib.mkEnableOption "Cullen winery dashboards + vinsight-local FastAPI server";

    dashboardsDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${hostConfig.user}/cellar-manager/dashboards";
      description = "Directory of static dashboard HTML/CSV files, mounted at /dashboards/ by the FastAPI app. Defaults to the cellar-manager checkout so symlinked sub-dashboards (e.g. fruit-weights) resolve.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "cullen.ablz.au";
      description = "Public FQDN. Cloudflare A record is synced to homelab.localProxy.localIp.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8421;
      description = "Loopback port the FastAPI app binds to. Nginx proxies https://fqdn to 127.0.0.1:<port>.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User to run the FastAPI server and sync timer as. Needs read on dashboardsDir.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Primary group of user. systemd-tmpfiles skips the rule silently if the group can't be resolved, so this must be a real group on the host.";
    };

    envFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/mcp/vinsight.env";
      description = "Env file containing VINSIGHT_API_KEY. Decrypted by homelab.mcp.vinsight.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cullen-dashboard";
      description = "Persistent location for the SQLite mirror.";
    };

    syncOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*:0/30";
      description = "systemd OnCalendar spec for the incremental Vinsight sync timer.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.cullen-dashboard-init = {
      description = "Seed local Vinsight mirror if missing";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        EnvironmentFile = cfg.envFile;
        ExecStart = seedScript;
        TimeoutStartSec = "15min";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [cfg.stateDir];
      };
    };

    systemd.services.cullen-dashboard-sync = {
      description = "Incremental Vinsight audit-log sync for Cullen dashboards";
      after = ["network-online.target" "cullen-dashboard-init.service"];
      wants = ["network-online.target"];
      requires = ["cullen-dashboard-init.service"];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        EnvironmentFile = cfg.envFile;
        ExecStart = "${vinsight} ${baseArgs} run";
        TimeoutStartSec = "10min";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [cfg.stateDir];
      };
    };

    systemd.timers.cullen-dashboard-sync = {
      description = "Run vinsight-sync every ${cfg.syncOnCalendar}";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.syncOnCalendar;
        OnBootSec = "3min";
        Persistent = true;
        Unit = "cullen-dashboard-sync.service";
      };
    };

    systemd.services.cullen-dashboard = {
      description = "Cullen winery dashboards (FastAPI + static)";
      after = ["network.target" "cullen-dashboard-init.service"];
      requires = ["cullen-dashboard-init.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        EnvironmentFile = cfg.envFile;
        ExecStart = "${vinsight} ${baseArgs} serve --host 127.0.0.1 --port ${toString cfg.port} --dashboards ${cfg.dashboardsDir}";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [cfg.stateDir];
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    # See #253 audit. Skipped — small FastAPI dashboard with no
    # actionable failure log fingerprint; outages surface via the Kuma
    # HTTP monitor (and via the sync timer's own systemd state).
    homelab.monitoring.errorPatterns = [];

    # Redirect the root path to the dashboards index. Uses an exact match so
    # it takes precedence over localProxy's prefix `/` proxy without breaking
    # /api or /dashboards/* (those continue to fall through to the proxy).
    services.nginx.virtualHosts.${cfg.fqdn}.locations."= /".return = "301 /dashboards/";
  };
}
