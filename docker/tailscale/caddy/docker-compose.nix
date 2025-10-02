{config, ...}: {
  systemd.services.caddy-tailscale-stack = {
    description = "Caddy Tailscale Docker Compose Stack";

    restartIfChanged = false;
    reloadIfChanged = true;

    # This service requires the Docker daemon to be running.
    requires = ["docker.service" "network-online.target"];

    # It should start after the Docker daemon and network are ready.
    # We also add the mount point dependency to ensure the Caddyfile, etc. are available.
    after = ["docker.service" "network-online.target"];

    # This section corresponds to the [Service] block in a systemd unit file.
    serviceConfig = {
      # 'oneshot' is perfect for commands that start a process and then exit.
      # 'docker compose up -d' does exactly this.
      Type = "oneshot";

      # This tells systemd that even though the start command exited,
      # the service should be considered 'active' until the stop command is run.
      RemainAfterExit = true;

      # The working directory where docker-compose.yml is located.
      WorkingDirectory = "/home/abl030/nixosconfig/docker/tailscale/caddy";

      # Command to start the containers.
      # We use config.virtualisation.docker.package to get the correct path to the Docker binary.
      # --build: Rebuilds the Caddy image if the Dockerfile changes.
      # --remove-orphans: Cleans up containers for services that are no longer in the compose file.
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";

      # Command to stop and remove the containers.
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";

      # Optional: Command to reload the service, useful for applying changes.
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";

      # StandardOutput and StandardError can be useful for debugging with journalctl.
      StandardOutput = "journal";
      StandardError = "journal";
    };

    # This section corresponds to the [Install] block in a systemd unit file.
    # This ensures the service is started automatically on boot.
    wantedBy = ["multi-user.target"];
  };

  # --- NEW ---
  # The service that performs the update.
  # This service is only meant to be run by the timer or manually.
  systemd.services.caddy-tailscale-updater = {
    description = "Weekly updater for the Caddy Tailscale Docker stack";
    serviceConfig = {
      Type = "oneshot";
      # The WorkingDirectory is critical, so docker-compose finds the right files.
      WorkingDirectory = "/home/abl030/nixosconfig/docker/tailscale/caddy";
    };
    # We create a self-contained script to be executed.
    script = ''
      set -e  # Exit immediately if a command exits with a non-zero status.
      echo "--- [$(date)] Starting scheduled Caddy update ---"

      # Get the full path to the docker binary
      DOCKER_BIN="${config.virtualisation.docker.package}/bin/docker"

      # Step 1: Rebuild the caddy service, pulling its base images.
      echo "Building 'caddy' service with --pull..."
      $DOCKER_BIN compose build --pull caddy

      # Step 2: Restart the stack to apply the newly built image.
      echo "Restarting stack to apply new image..."
      $DOCKER_BIN compose up -d --force-recreate --remove-orphans

      # Step 3: Prune old images.
      echo "Pruning old Docker images..."
      $DOCKER_BIN image prune -f

      echo "--- [$(date)] Scheduled Caddy update complete ---"
    '';
  };

  # --- NEW ---
  # The timer that triggers the updater service.
  systemd.timers.caddy-tailscale-updater = {
    description = "Weekly timer to update the Caddy Tailscale Docker stack";
    wantedBy = ["timers.target"];
    timerConfig = {
      # Runs at 1:00 AM every Sunday.
      OnCalendar = "Sun 01:00:00";
      # If the system was down at the scheduled time, run the job
      # as soon as it's up again.
      Persistent = true;
    };
  };
}
