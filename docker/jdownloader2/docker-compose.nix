{ config, pkgs, inputs, ... }:

{
  systemd.services.jdownloader2-stack = {
    description = "JDownloader2 Docker Compose Stack";

    restartIfChanged = false;
    reloadIfChanged = true;

    # This service requires Docker and the data mount to be ready.
    requires = [ "docker.service" "network-online.target" "mnt-data.mount" ];
    after = [ "docker.service" "network-online.target" "mnt-data.mount" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # The working directory where docker-compose.yml is located.
      WorkingDirectory = "/home/abl030/nixosconfig/docker/jdownloader2";

      # Command to start the containers.
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";

      # Command to stop and remove the containers.
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";

      # Command to reload the service.
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";

      StandardOutput = "journal";
      StandardError = "journal";
    };

    # This ensures the service is started automatically on boot.
    wantedBy = [ "multi-user.target" ];
  };
}
