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

    requires = [
      "docker.service"
      "network-online.target"
      "mnt-data.mount"
      "fuse-mergerfs-movies.service"
      "fuse-mergerfs-tv.service"
      "fuse-mergerfs-music.service"
    ];
    after = [
      "docker.service"
      "network-online.target"
      "mnt-data.mount"
      "fuse-mergerfs-movies.service"
      "fuse-mergerfs-tv.service"
      "fuse-mergerfs-music.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set the working directory to where your docker-compose.yml is located
      WorkingDirectory = "/home/abl030/nixosconfig/docker/plex/";

      # docker-compose.yml is the default filename, so the -f flag is not needed
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";

      # A simple reload is just to bring the stack up again with any new images
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    # Enable the service to start on boot
    wantedBy = [ "multi-user.target" ];
  };
}
