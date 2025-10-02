{
  config,
  pkgs,
  inputs,
  ...
}: {
  systemd.services.management-epi-stack = {
    description = "Docker Management Epi Compose Stack";

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
      WorkingDirectory = "/home/abl030/nixosconfig/docker/management/epi_management";

      # Command to start the containers.
      # We use config.virtualisation.docker.package to get the correct path to the Docker binary.
      # --build: Rebuilds the Caddy image if the Dockerfile changes.
      # --remove-orphans: Cleans up containers for services that are no longer in the compose file.
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";

      # Command to stop and remove the containers.
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";

      # Optional: Command to reload the service, useful for applying changes.
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";

      # Restart the service automatically if it fails
      Restart = "on-failure";
      RestartSec = "30s";

      # StandardOutput and StandardError can be useful for debugging with journalctl.
      StandardOutput = "journal";
      StandardError = "journal";
    };

    # This section corresponds to the [Install] block in a systemd unit file.
    # This ensures the service is started automatically on boot.
    wantedBy = ["multi-user.target"];
  };

  # ========================================================================= #
  # NEW SERVICE BLOCK: Run Watchtower once on boot to update containers       #
  # ========================================================================= #
  systemd.services.watchtower-run-once = {
    description = "Run Watchtower once on boot to update containers";

    # This service must run after the main docker compose stack is up,
    # after the /mnt/data mount is available, and late in the boot process.
    after = ["management-epi-stack.service" "mnt-data.automount" "multi-user.target" "tdarr-epi-stack.service"];
    requires = ["management-epi-stack.service" "mnt-data.automount" "tdarr-epi-stack.service"];

    serviceConfig = {
      # This is a one-off command that starts, runs, and exits.
      Type = "oneshot";

      # The full docker command to run watchtower once.
      # --rm: Automatically remove the container when it exits.
      # -v /var/run/docker.sock...: Grants access to the Docker daemon.
      # --run-once: Tells Watchtower to run its update check and then exit.
      # --cleanup: Removes old images after a successful update.
      # --include-stopped: Also updates containers that are not currently running.
      ExecStart = ''
        ${config.virtualisation.docker.package}/bin/docker run --rm \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          --run-once \
          --cleanup \
          --include-stopped
      '';

      # Log output to the system journal for debugging.
      StandardOutput = "journal";
      StandardError = "journal";
    };

    # Ensures the service is started automatically on boot.
    wantedBy = ["multi-user.target"];
  };
}
