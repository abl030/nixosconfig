{
  config,
  pkgs,
  ...
}: let
  stackName = "music-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile;
  dbTemplate = ./database.json.template;
  initSql = ./init.sql;

  # Secrets
  encEnv = config.homelab.secrets.sopsFile "music.env";
  encAcmeEnv = config.homelab.secrets.sopsFile "acme-cloudflare.env";
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
  gettextBin = "${pkgs.gettext}/bin/envsubst";
in {
  systemd.services.${stackName} = {
    description = "Music Stack (Lidarr + Ombi + Filebrowser) Docker Compose";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = requiresBase;
    after = requiresBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      Environment = [
        "COMPOSE_PROJECT_NAME=music"
        "CADDY_FILE=${caddyFile}"
        "INIT_SQL=${initSql}"
      ];

      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"

        # Create directories
        "/run/current-system/sw/bin/mkdir -p /mnt/docker/ombi/config"
        "/run/current-system/sw/bin/mkdir -p /mnt/docker/ombi/db"
        "/run/current-system/sw/bin/mkdir -p /mnt/docker/music/lidarr"
        "/run/current-system/sw/bin/mkdir -p /mnt/docker/music/filebrowser"

        # Decrypt secrets
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runAcmeEnv} ${encAcmeEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv} ${runAcmeEnv}"

        # Generate Ombi database.json from template
        (pkgs.writeShellScript "generate-ombi-json" ''
          set -a
          source ${runEnv}
          set +a
          ${gettextBin} < ${dbTemplate} > /mnt/docker/ombi/config/database.json
        '')

        # Ensure permissions
        "/run/current-system/sw/bin/chown -R 99:100 /mnt/docker/ombi/config"
        "/run/current-system/sw/bin/chown -R 99:100 /mnt/docker/music/lidarr"
        "/run/current-system/sw/bin/chown -R 99:100 /mnt/docker/music/filebrowser"
      ];

      # Start
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
