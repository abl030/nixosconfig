{
  config,
  pkgs,
  ...
}: let
  stackName = "uptime-kuma-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;

  # Secrets
  # Pointing to the correct location in your flake structure
  encEnv = ../../secrets/secrets/uptime-kuma.env;
  ageKey = "/root/.config/sops/age/keys.txt";

  # Runtime Env Path
  runEnv = "/run/secrets/${stackName}.env";

  # Dependencies
  requiresBase = ["docker.service" "network-online.target" "mnt-data.mount"];

  # Helper for the docker binary
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
in {
  systemd.services.${stackName} = {
    description = "Uptime Kuma & AutoKuma Docker Compose Stack";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = requiresBase;
    after = requiresBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      Environment = "COMPOSE_PROJECT_NAME=uptime-kuma";

      # Decrypt secrets
      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"
      ];

      # Start
      ExecStart = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

      # Stop
      ExecStop = "${dockerBin} compose -f ${composeFile} down";

      # Reload
      ExecReload = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
