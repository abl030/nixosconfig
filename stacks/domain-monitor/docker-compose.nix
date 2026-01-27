{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  stackName = "domain-monitor-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "domain-monitor-docker-compose.yml";
  };
  dockerFile = builtins.path {
    path = ./Dockerfile;
    name = "domain-monitor-Dockerfile";
  };
  entrypoint = builtins.path {
    path = ./entrypoint.sh;
    name = "domain-monitor-entrypoint.sh";
  };

  encEnv = config.homelab.secrets.sopsFile "domain-monitor.env";
  userUid = let
    uid = config.users.users.${config.homelab.user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;
  userGroup = config.users.users.${config.homelab.user}.group or "users";
  runEnv = "/run/user/${toString userUid}/secrets/${stackName}.env";

  podmanCompose = "${pkgs.podman-compose}/bin/podman-compose";
  podmanBin = "${pkgs.podman}/bin/podman";
  ageKey = "${config.homelab.userHome}/.config/sops/age/keys.txt";

  srcPath = inputs.domain-monitor-src;
  dependsOn = ["network-online.target" "mnt-data.mount"];
  inherit (config.homelab.containers) dataRoot;
in {
  networking.firewall.allowedTCPPorts = [8089];

  homelab.localProxy.hosts = lib.mkAfter [
    {
      host = "domains.ablz.au";
      port = 8089;
    }
  ];

  systemd = {
    services = {
      ${stackName} = {
        description = "Domain Monitor Podman Compose Stack";
        restartIfChanged = true;
        reloadIfChanged = false;
        requires = dependsOn ++ ["podman-system-service.service"];
        after = dependsOn ++ ["podman-system-service.service"];
        # Restart when podman-system-service restarts
        bindsTo = ["podman-system-service.service"];

        unitConfig = {
          RequiresMountsFor = ["/mnt/data"];
          # Allow retries after dependency failures
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.homelab.user;
          PermissionsStartOnly = true;
          Environment = [
            "COMPOSE_PROJECT_NAME=domain-monitor"
            "DATA_ROOT=${dataRoot}"
            "DOMAIN_MONITOR_SRC=${srcPath}"
            "HOME=${config.homelab.userHome}"
            "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
            "PATH=/run/current-system/sw/bin:/run/wrappers/bin"
          ];

          ExecStartPre = [
            "/run/current-system/sw/bin/mkdir -p /tmp/domain-monitor-build"
            "/run/current-system/sw/bin/cp -f ${composeFile} /tmp/domain-monitor-build/docker-compose.yml"
            "/run/current-system/sw/bin/cp -f ${dockerFile} /tmp/domain-monitor-build/Dockerfile"
            "/run/current-system/sw/bin/cp -f ${entrypoint} /tmp/domain-monitor-build/entrypoint.sh"
            "/run/current-system/sw/bin/chown -R ${toString userUid}:${userGroup} /tmp/domain-monitor-build"
            "/run/current-system/sw/bin/mkdir -p ${dataRoot}/domain-monitor/db ${dataRoot}/domain-monitor/www"
            "/run/current-system/sw/bin/chown -R ${toString userUid}:${userGroup} ${dataRoot}/domain-monitor"

            "/run/current-system/sw/bin/mkdir -p /run/user/${toString userUid}/secrets"
            ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
            "/run/current-system/sw/bin/chmod 600 ${runEnv}"
            "/run/current-system/sw/bin/chown ${config.homelab.user}:${userGroup} ${runEnv}"
          ];

          ExecStart = "${podmanCompose} -f /tmp/domain-monitor-build/docker-compose.yml --env-file ${runEnv} up -d --build --remove-orphans";
          ExecStop = "${podmanCompose} -f /tmp/domain-monitor-build/docker-compose.yml down";
          ExecReload = "${podmanCompose} -f /tmp/domain-monitor-build/docker-compose.yml --env-file ${runEnv} up -d --build --remove-orphans";

          Restart = "on-failure";
          RestartSec = "30s";
        };

        wantedBy = ["multi-user.target"];
      };

      domain-monitor-cron = {
        description = "Domain Monitor Cron Job";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Environment = [
            "HOME=${config.homelab.userHome}"
            "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString userUid}/bus"
          ];
          ExecStart = "${pkgs.shadow}/bin/runuser -u ${config.homelab.user} -- ${podmanBin} exec -i domain-monitor-app php /var/www/html/cron/check_domains.php";
        };
      };
    };

    timers = {
      domain-monitor-cron = {
        description = "Run Domain Monitor Cron every 5 minutes";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*:0/5";
          Persistent = true;
          Unit = "domain-monitor-cron.service";
        };
      };
    };
  };
}
