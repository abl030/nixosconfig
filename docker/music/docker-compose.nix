{
  config,
  pkgs,
  ...
}: let
  stackName = "music-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile;

  # Secrets
  # 1. Stack-specific secrets
  encEnv = ../../secrets/secrets/music.env;
  # 2. Shared ACME/Cloudflare secrets
  encAcmeEnv = ../../secrets/secrets/acme-cloudflare.env;

  ageKey = "/root/.config/sops/age/keys.txt";

  # Runtime Env Paths
  runEnv = "/run/secrets/${stackName}.env";
  runAcmeEnv = "/run/secrets/${stackName}-acme.env";

  # Dependencies
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

      # Set Project Name and pass Caddyfile path
      Environment = [
        "COMPOSE_PROJECT_NAME=music"
        "CADDY_FILE=${caddyFile}"
      ];

      # Decrypt secrets
      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"

        # 1. Decrypt Music Env
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"

        # 2. Decrypt Shared Acme Env
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runAcmeEnv} ${encAcmeEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runAcmeEnv}"
      ];

      # Start
      # We pass both env files.
      ExecStart = "${dockerBin} compose -f ${composeFile} --env-file ${runAcmeEnv} --env-file ${runEnv} up -d --remove-orphans";

      # Stop
      ExecStop = "${dockerBin} compose -f ${composeFile} --env-file ${runAcmeEnv} --env-file ${runEnv} down";

      # Reload
      ExecReload = "${dockerBin} compose -f ${composeFile} --env-file ${runAcmeEnv} --env-file ${runEnv} up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
