{ config, pkgs, inputs, ... }:

{

  # ===================================================================
  # This is your existing service for managing the main Immich stack.
  # It is unchanged.
  # ===================================================================
  systemd.services.immich-stack = {
    description = "Immich Docker Compose Stack";
    requires = [ "docker.service" "network-online.target" "mnt-data.automount" ];
    after = [ "docker.service" "network-online.target" "mnt-data.automount" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/home/abl030/nixosconfig/docker/immich";
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans ";
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose down";
      ExecReload = "${config.virtualisation.docker.package}/bin/docker compose up -d --remove-orphans";
      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = [ "multi-user.target" ];
  };


  # ===================================================================
  # NEW: The service that performs the nightly rebuild.
  # This defines WHAT to do.
  # ===================================================================
  systemd.services.immich-rebuild = {
    description = "Nightly rebuild service for the Immich stack";

    # This service should only run if the main stack is already active.
    requires = [ "immich-stack.service" ];
    after = [ "immich-stack.service" ];

    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/home/abl030/nixosconfig/docker/immich";

      # The command to execute. It pulls new images and rebuilds the
      # caddy service if its Dockerfile or context has changed.
      ExecStart = "${config.virtualisation.docker.package}/bin/docker compose up -d --build --remove-orphans";
    };
  };


  # ===================================================================
  # NEW: The timer that triggers the nightly rebuild.
  # This defines WHEN to do it.
  # ===================================================================
  systemd.timers.immich-rebuild = {
    description = "Timer to trigger nightly Immich stack rebuild";

    # This enables the timer, so it starts on boot.
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run at 1:00 AM every day.
      OnCalendar = "*-*-* 01:00:00";

      # If the system was powered off at 1:00 AM, run the job
      # as soon as it boots up again.
      Persistent = true;

      # The unit to activate when the timer elapses.
      # By convention, NixOS links `immich-rebuild.timer` to `immich-rebuild.service`.
      Unit = "immich-rebuild.service";
    };
  };

}
