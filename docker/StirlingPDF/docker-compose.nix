{config, ...}: {
  systemd.services.StirlingPDF-stack = {
    description = "StirlingPDF Docker Compose Stack";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = ["docker.service" "network-online.target"];
    after = ["docker.service" "network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "COMPOSE_PROJECT_NAME=stirlingpdf";

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
