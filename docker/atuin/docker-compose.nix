{
  config,
  pkgs,
  ...
}: let
  stackName = "atuin-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;

  # Secrets
  encEnv = ../../secrets/secrets/atuin.env;
  ageKey = "/root/.config/sops/age/keys.txt";

  # Runtime Env Path
  runEnv = "/run/secrets/${stackName}.env";

  # Dependencies
  requiresBase = ["docker.service" "network-online.target"];

  # Helper for the docker binary
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
in {
  systemd.services.${stackName} = {
    description = "Atuin Docker Compose Stack";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = requiresBase;
    after = requiresBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set Project Name
      Environment = "COMPOSE_PROJECT_NAME=atuin";

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
