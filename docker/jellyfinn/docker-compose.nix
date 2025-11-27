{
  config,
  pkgs,
  ...
}: let
  stackName = "jellyfin-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile;
  inotifyScript = ./inotify-recv.sh;

  # Secrets
  encEnv = ../../secrets/secrets/jellyfin.env;
  ageKey = "/root/.config/sops/age/keys.txt";

  # Dependencies
  requiresBase = [
    "docker.service"
    "network-online.target"
    "mnt-data.mount"
    "fuse-mergerfs-movies.service"
    "fuse-mergerfs-tv.service"
    "fuse-mergerfs-music.service"
  ];

  # Derived
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Jellyfin Docker Compose Stack";
    restartIfChanged = false;
    reloadIfChanged = true;
    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set Project Name and pass file paths
      Environment = [
        "COMPOSE_PROJECT_NAME=jellyfin"
        "CADDY_FILE=${caddyFile}"
        "INOTIFY_SCRIPT=${inotifyScript}"
      ];

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
