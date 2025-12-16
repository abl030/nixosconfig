{config, ...}: {
  systemd.services.plex-stack = {
    description = "Plex Docker Compose Stack";
    restartIfChanged = true;
    reloadIfChanged = false;

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

      # ─── ADDED ───
      Environment = "COMPOSE_PROJECT_NAME=plex";
      # ─────────────

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
