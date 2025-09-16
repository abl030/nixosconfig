{ config, pkgs, ... }:

{
  # ===================================================================
  # This service starts and stops the Plex stack.
  # It is activated on boot and managed by `systemctl`.
  # ===================================================================
  systemd.services.plex-stack = {
    description = "Plex Docker Compose Stack";
    # Ensures this service doesn't restart automatically during a nixos-rebuild
    restartIfChanged = false;
    reloadIfChanged = false; # Set to false as reload is not explicitly defined differently than start

    # Dependencies: Wait for Docker, networking, and your data mount to be ready
    requires = [ "docker.service" "network-online.target" "mnt-data.mount" ];
    after = [ "docker.service" "network-online.target" "mnt-data.mount" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set the working directory to where your docker-compose.plex.yml is located
      WorkingDirectory = "/home/abl030/nixosconfig/docker/plex/";

      # Use the -f flag to specify the exact compose file name
      # This prevents conflicts if other compose files are in the same directory
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose -f docker-compose.plex.yml up -d --remove-orphans";
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose -f docker-compose.plex.yml down";

      # A simple reload is just to bring the stack up again with any new images
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose -f docker-compose.plex.yml up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    # Enable the service to start on boot
    wantedBy = [ "multi-user.target" ];
  };
}
