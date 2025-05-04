# ~/nixosconfig/kopia-schedule.nix
{ config, pkgs, ... }:

let
  # --- Configuration ---
  kopiaComposeDir = "/home/abl030/nixosconfig/docker/kopia"; # Absolute path
  composeFileName = "docker-compose.yml"; # Compose file name
  scheduleUser = "abl030"; # User running docker
  scheduleGroup = "docker"; # Group for the user
  # --- End Configuration ---

  # Get the explicit path to the docker binary provided by NixOS
  dockerBinary = "${pkgs.docker}/bin/docker";

in
{
  systemd.services = {
    # Service to START the Kopia Docker Compose stack
    kopia-compose-start = {
      description = "Start Kopia Docker Compose stack";
      serviceConfig = {
        Type = "oneshot";
        User = scheduleUser;
        Group = scheduleGroup;
        WorkingDirectory = kopiaComposeDir;
        # CORRECTED ExecStart: Use the docker binary path, then 'compose' as an argument
        ExecStart = "${dockerBinary} compose -f ${composeFileName} up -d";
      };
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
    };

    # Service to STOP the Kopia Docker Compose stack
    kopia-compose-stop = {
      description = "Stop Kopia Docker Compose stack";
      serviceConfig = {
        Type = "oneshot";
        User = scheduleUser;
        Group = scheduleGroup;
        WorkingDirectory = kopiaComposeDir;
        # CORRECTED ExecStart: Use the docker binary path, then 'compose' as an argument
        ExecStart = "${dockerBinary} compose -f ${composeFileName} down";
      };
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
    };
  };

  # --- Timers section remains unchanged ---
  systemd.timers = {
    kopia-compose-start = {
      description = "Timer to start Kopia Docker Compose at 11 PM";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 23:00:00";
        Persistent = true;
        Unit = "kopia-compose-start.service";
      };
    };
    kopia-compose-stop = {
      description = "Timer to stop Kopia Docker Compose at 2 PM";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 14:00:00";
        Persistent = true;
        Unit = "kopia-compose-stop.service";
      };
    };
  };
}
