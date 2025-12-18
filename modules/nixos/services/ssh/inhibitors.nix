{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.homelab.ssh;

  PID_PATH = "/tmp/ssh_sleep_block.pid";
  PID_PIPE = "pid_pipe";

  # Prevent sleeping on active SSH
  sleep_script =
    pkgs.writeScript "infinite-sleep"
    ''
      #!/bin/sh
      echo $$ >${PID_PATH}
      echo $$ >${PID_PIPE}
      sleep infinity
    '';

  inhibit_script =
    pkgs.writeScript "inhibit_script"
    ''
      #!/bin/sh
      systemd-inhibit --what=sleep --why="Active SSH session" --mode=block ${sleep_script} 0>&- &> /tmp/inhibit.out &
    '';

  ssh_script =
    pkgs.writeScript "ssh-session-handler"
    ''
      #!/bin/sh
      # This script runs when an ssh session opens/closes, and masks/unmasks
      # systemd sleep and hibernate targets.

      num_ssh=$(netstat -nt | awk '$4 ~ /:22$/ && $6 == "ESTABLISHED"' | wc -l)

      case "$PAM_TYPE" in
          open_session)
              if [ "$num_ssh" -gt 1 ]; then
                  exit
              fi

              logger "Starting sleep inhibitor"
              mkfifo ${PID_PIPE}
              ${inhibit_script}
              logger "Sleep inhibitor started with PID $(cat ${PID_PIPE})"
              rm ${PID_PIPE}
              ;;

          close_session)
              if [ "$num_ssh" -ne 0 ]; then
                  exit
              fi

              logger "Killing sleep inhibitor PID $(cat ${PID_PATH})"
              kill -9 $(cat ${PID_PATH}) && rm ${PID_PATH}
              ;;
          *)
              exit
      esac
    '';

  # Create a PATH with all required utilities for the cleanup service
  requiredPaths = lib.makeBinPath [
    pkgs.bash
    pkgs.procps
    pkgs.gnugrep
    pkgs.gawk
    pkgs.systemd
    pkgs.util-linux
    pkgs.coreutils
  ];

  monitor_script = pkgs.writeScript "session-monitor" ''
    #!${pkgs.bash}/bin/bash
    export PATH=${requiredPaths}:$PATH
    PID_FILE="/tmp/ssh_sleep_block.pid"

    check_sessions() {
        # Check for any pts sessions
        active_pts=$(who | grep -c "pts/")

        if [ "$active_pts" -eq 0 ] && [ -f "$PID_FILE" ]; then
            logger "No active pts sessions found, cleaning up inhibitor"
            pid_from_file=$(cat "$PID_FILE")

            inhibitor_info=$(systemd-inhibit --list | grep "sleep.*Active SSH")
            if [ ! -z "$inhibitor_info" ]; then
                logger "Found inhibitor: $inhibitor_info"
                if [ ! -z "$pid_from_file" ] && kill -0 "$pid_from_file" 2>/dev/null; then
                    logger "Killing sleep inhibitor PID $pid_from_file"
                    kill -9 "$pid_from_file"
                else
                    inhibitor_pid=$(echo "$inhibitor_info" | awk '{print $NF}')
                    if [[ "$inhibitor_pid" =~ ^[0-9]+$ ]]; then
                        logger "Killing sleep inhibitor PID $inhibitor_pid"
                        kill -9 "$inhibitor_pid"
                    fi
                fi
            fi
            rm -f "$PID_FILE"
        fi
    }

    while true; do
        check_sessions
        sleep 1
    done
  '';
in {
  config = lib.mkIf cfg.enable {
    # 1. Apply PAM script to sshd
    security.pam.services.sshd.text = lib.mkDefault (
      lib.mkAfter
      "session optional pam_exec.so quiet ${ssh_script}"
    );

    # 2. Enable the cleanup monitor
    systemd.services.session-monitor = {
      description = "Monitor SSH/Tailscale sessions for sleep inhibition";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${monitor_script}";
        Restart = "always";
        RestartSec = "5s";
        Environment = "PATH=${requiredPaths}";
      };
    };
  };
}
