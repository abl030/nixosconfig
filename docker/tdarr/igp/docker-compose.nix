{config, ...}: {
  systemd.services."tdarr-igp-stack" = {
    description = "Tdarr IGP Compose Stack";
    restartIfChanged = false;
    reloadIfChanged = true;
    requires = ["docker.service" "network-online.target" "mnt-data.mount"];
    after = ["docker.service" "network-online.target" "mnt-data.mount"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "COMPOSE_PROJECT_NAME=tdarr-igp";

      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose -f ${./docker-compose.yml} up -d --remove-orphans";
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose -f ${./docker-compose.yml} down";
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose -f ${./docker-compose.yml} up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
