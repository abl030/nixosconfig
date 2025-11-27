{config, ...}: {
  systemd.services.management-epi-stack = {
    description = "Docker Management Epi Compose Stack";
    restartIfChanged = false;
    reloadIfChanged = true;
    requires = ["docker.service" "network-online.target"];
    after = ["docker.service" "network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "COMPOSE_PROJECT_NAME=management-epi";

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

  # Watchtower run-once service
  systemd.services.watchtower-run-once = {
    description = "Run Watchtower once on boot to update containers";
    after = ["management-epi-stack.service" "mnt-data.automount" "multi-user.target" "tdarr-epi-stack.service"];
    requires = ["management-epi-stack.service" "mnt-data.automount" "tdarr-epi-stack.service"];

    serviceConfig = {
      Type = "oneshot";
      # This runs a standalone container, so it doesn't need compose contexts
      ExecStart = ''
        ${config.virtualisation.docker.package}/bin/docker run --rm \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          --run-once \
          --cleanup \
          --include-stopped
      '';
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
