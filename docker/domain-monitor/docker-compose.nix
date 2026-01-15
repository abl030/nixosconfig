{
  config,
  pkgs,
  inputs, # Access inputs for domain-monitor-src
  ...
}: let
  stackName = "domain-monitor-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  dockerFile = ./Dockerfile;
  entrypoint = ./entrypoint.sh;

  # Secrets
  encEnv = ../../secrets/secrets/domain-monitor.env;
  ageKey = "/root/.config/sops/age/keys.txt";
  runEnv = "/run/secrets/${stackName}.env";

  requiresBase = ["docker.service" "network-online.target" "mnt-data.mount"];
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";

  # The source from flake inputs
  srcPath = inputs.domain-monitor-src;
in {
  # Grouped systemd configurations to satisfy statix [W20]
  systemd = {
    services = {
      # 1. The Stack
      ${stackName} = {
        description = "Domain Monitor Docker Compose Stack";
        restartIfChanged = true;
        reloadIfChanged = false;
        requires = requiresBase;
        after = requiresBase;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;

          Environment = [
            "COMPOSE_PROJECT_NAME=domain-monitor"
            "DOMAIN_MONITOR_SRC=${srcPath}"
          ];

          # Copy build files to a temp dir so Docker can 'build: .' context correctly
          # We need the Dockerfile and Entrypoint in the same dir as compose execution
          # but we also need to pass the src path via env var.
          ExecStartPre = [
            "/run/current-system/sw/bin/mkdir -p /tmp/domain-monitor-build"
            "/run/current-system/sw/bin/cp -f ${dockerFile} /tmp/domain-monitor-build/Dockerfile"
            "/run/current-system/sw/bin/cp -f ${entrypoint} /tmp/domain-monitor-build/entrypoint.sh"

            # Decrypt secrets
            "/run/current-system/sw/bin/mkdir -p /run/secrets"
            ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
            "/run/current-system/sw/bin/chmod 600 ${runEnv}"
          ];

          # We run compose from the /tmp build dir so it finds the Dockerfile
          ExecStart = "${dockerBin} compose -f ${composeFile} --project-directory /tmp/domain-monitor-build --env-file ${runEnv} up -d --build --remove-orphans";

          ExecStop = "${dockerBin} compose -f ${composeFile} --project-directory /tmp/domain-monitor-build down";
          ExecReload = "${dockerBin} compose -f ${composeFile} --project-directory /tmp/domain-monitor-build --env-file ${runEnv} up -d --build --remove-orphans";

          Restart = "on-failure";
          RestartSec = "30s";
        };

        wantedBy = ["multi-user.target"];
      };

      # 2. The Cron Job (Service)
      domain-monitor-cron = {
        description = "Domain Monitor Cron Job";
        serviceConfig = {
          Type = "oneshot";
          # Run the domain check cron inside the container
          ExecStart = "${dockerBin} exec -i domain-monitor-app php /var/www/html/cron/check_domains.php";
        };
      };
    };

    timers = {
      # 3. The Cron Job (Timer) - Runs every 5 minutes
      domain-monitor-cron = {
        description = "Run Domain Monitor Cron every 5 minutes";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*:0/5"; # Every 5 minutes
          Persistent = true;
          Unit = "domain-monitor-cron.service";
        };
      };
    };
  };
}
