_: {
  systemd = {
    timers = {
      kopia-stack-start = {
        description = "Timer to start Kopia Docker Compose at 11 PM";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-* 23:00:00";
          Persistent = true;
          Unit = "kopia-stack.service";
        };
      };

      kopia-stack-stop = {
        description = "Timer to stop Kopia Docker Compose at 2 PM";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-* 14:00:00";
          Persistent = true;
          Unit = "kopia-stack-stop.service";
        };
      };
    };

    services.kopia-stack-stop = {
      description = "Stop Kopia Docker Compose stack";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/systemctl stop kopia-stack.service";
      };
    };
  };
}
