{config, ...}: {
  # Group all systemd units under a single attribute set.
  # This mirrors the structure of NixOS options (systemd.services, systemd.timers)
  # and prevents merge conflicts.
  systemd = {
    # ===================================================================
    # This is the primary service that starts and stops the Immich stack.
    # It is activated on boot and managed by `systemctl`.
    # ===================================================================
    services.immich-stack = {
      description = "Immich Docker Compose Stack";
      restartIfChanged = false;
      reloadIfChanged = true;
      requires = ["docker.service" "network-online.target" "mnt-data.mount"];
      after = ["docker.service" "network-online.target" "mnt-data.mount"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "/home/abl030/nixosconfig/docker/immich";
        # On initial start, we just bring the stack up.
        # A build is not strictly necessary here, but doesn't hurt.
        ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";
        ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";
        ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";
        Restart = "on-failure";
        RestartSec = "30s";
        StandardOutput = "journal";
        StandardError = "journal";
      };

      wantedBy = ["multi-user.target"];
    };

    # ===================================================================
    # This service performs the complete update and restart procedure.
    # It is designed to be triggered by the systemd timer below.
    # ===================================================================
    services.immich-updater = {
      description = "Weekly updater for the Immich Docker stack";

      # This service should only run if the main stack is already active.
      requires = ["immich-stack.service"];
      after = ["immich-stack.service"];

      serviceConfig = {
        Type = "oneshot";
        # The WorkingDirectory is critical for docker-compose to find the correct files.
        WorkingDirectory = "/home/abl030/nixosconfig/docker/immich";
      };

      # We define a self-contained script here. This is the idiomatic NixOS way.
      script = ''
        set -e # Exit immediately if any command fails.
        echo "--- [$(date)] Starting scheduled Immich stack update ---"

        # Store the path to the docker binary in a variable for clarity.
        DOCKER_BIN="${config.virtualisation.docker.package}/bin/docker"

        # Step 1: Pull the latest versions of all pre-built images defined in docker-compose.yml
        # (immich-server, tailscale, redis, etc.)
        echo "Pulling latest pre-built images..."
        $DOCKER_BIN compose pull

        # Step 2: Explicitly rebuild the 'caddy' service, telling it to pull its own fresh base images.
        echo "Rebuilding 'caddy' service with fresh base images..."
        $DOCKER_BIN compose build --pull caddy

        # Step 3: Restart the entire stack to apply all updates (pulled and built).
        # --force-recreate ensures containers are replaced even if config is unchanged.
        echo "Restarting stack to apply new images..."
        $DOCKER_BIN compose up -d --force-recreate --remove-orphans

        # Step 4: Clean up old, unused Docker images to save disk space.
        echo "Pruning old Docker images..."
        $DOCKER_BIN image prune -f

        echo "--- [$(date)] Scheduled Immich stack update complete ---"
      '';
    };

    # ===================================================================
    # This timer triggers the updater service on a schedule.
    # This defines WHEN the update happens.
    # ===================================================================
    timers.immich-updater = {
      description = "Timer to trigger weekly Immich stack update";

      # This ensures the timer is enabled and starts on boot.
      wantedBy = ["timers.target"];

      timerConfig = {
        # Runs at 1:00 AM every Sunday. You can change this schedule as needed.
        # e.g., "daily" or "*-*-* 02:00:00" for 2 AM every day.
        OnCalendar = "Sun 01:00:00";

        # If the system was powered off at the scheduled time, run the job
        # 5 minutes after the next boot.
        Persistent = true;
      };
    };
  };
}
