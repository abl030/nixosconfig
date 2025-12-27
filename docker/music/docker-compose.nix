{
  config,
  pkgs,
  ...
}: let
  stackName = "music-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;

  # Secrets (Using the same age key location as other stacks)
  # Ensure you create a 'music.env' or reuse an existing one if suitable,
  # though Lidarr doesn't strictly need one for basic setup.
  # I will placeholder it here; if you don't have secrets yet,
  # you can comment out the SOPS lines or create an empty env file.
  encEnv = ../../secrets/secrets/music.env;
  ageKey = "/root/.config/sops/age/keys.txt";

  # Runtime Env Path
  runEnv = "/run/secrets/${stackName}.env";

  # Dependencies
  # We require the new RW fuse mount and the network online
  requiresBase = [
    "docker.service"
    "network-online.target"
    "fuse-mergerfs-music-rw.service"
  ];

  # Helper for the docker binary
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
in {
  systemd.services.${stackName} = {
    description = "Music Stack (Lidarr+) Docker Compose";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = requiresBase;
    after = requiresBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set Project Name
      Environment = "COMPOSE_PROJECT_NAME=music";

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
