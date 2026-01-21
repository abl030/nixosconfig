{
  config,
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
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podmanCompose = "${pkgs.podman-compose}/bin/podman-compose";
  podmanBin = "${pkgs.podman}/bin/podman";
  ageKey = "${config.homelab.userHome}/.config/sops/age/keys.txt";

  srcPath = inputs.domain-monitor-src;
  dependsOn = ["network-online.target" "mnt-data.mount"];
in {
  systemd = {
    services = {
      ${stackName} = {
        description = "Domain Monitor Podman Compose Stack";
        restartIfChanged = true;
        reloadIfChanged = false;
        requires = dependsOn ++ ["podman-system-service.service"];
        after = dependsOn ++ ["podman-system-service.service"];

        unitConfig.RequiresMountsFor = ["/mnt/data"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.homelab.user;
          Environment = [
            "COMPOSE_PROJECT_NAME=domain-monitor"
            "DOMAIN_MONITOR_SRC=${srcPath}"
            "HOME=${config.homelab.userHome}"
            "XDG_RUNTIME_DIR=/run/user/%U"
          ];

          ExecStartPre = [
            "/run/current-system/sw/bin/mkdir -p /tmp/domain-monitor-build"
            "/run/current-system/sw/bin/cp -f ${dockerFile} /tmp/domain-monitor-build/Dockerfile"
            "/run/current-system/sw/bin/cp -f ${entrypoint} /tmp/domain-monitor-build/entrypoint.sh"

            "/run/current-system/sw/bin/mkdir -p /run/user/%U/secrets"
            ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
            "/run/current-system/sw/bin/chmod 600 ${runEnv}"
          ];

          ExecStart = "${podmanCompose} -f ${composeFile} --project-directory /tmp/domain-monitor-build --env-file ${runEnv} up -d --build --remove-orphans";
          ExecStop = "${podmanCompose} -f ${composeFile} --project-directory /tmp/domain-monitor-build down";
          ExecReload = "${podmanCompose} -f ${composeFile} --project-directory /tmp/domain-monitor-build --env-file ${runEnv} up -d --build --remove-orphans";

          Restart = "on-failure";
          RestartSec = "30s";
        };

        wantedBy = ["multi-user.target"];
      };

      domain-monitor-cron = {
        description = "Domain Monitor Cron Job";
        serviceConfig = {
          Type = "oneshot";
          User = config.homelab.user;
          Environment = [
            "HOME=${config.homelab.userHome}"
            "XDG_RUNTIME_DIR=/run/user/%U"
          ];
          ExecStart = "${podmanBin} exec -i domain-monitor-app php /var/www/html/cron/check_domains.php";
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
