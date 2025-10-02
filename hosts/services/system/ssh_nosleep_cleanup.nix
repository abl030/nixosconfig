{
  config,
  lib,
  pkgs,
  ...
}: let
  # Create a PATH with all required utilities
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

    # Set PATH to include all required utilities
    export PATH=${requiredPaths}:$PATH

    PID_FILE="/tmp/ssh_sleep_block.pid"

    check_sessions() {
        # Check for any pts sessions
        active_pts=$(who | grep -c "pts/")

        if [ "$active_pts" -eq 0 ] && [ -f "$PID_FILE" ]; then
            # No active pts sessions and PID file exists
            logger "No active pts sessions found, cleaning up inhibitor"

            # Get PID from the PID file first
            pid_from_file=$(cat "$PID_FILE")

            # Find the sleep inhibitor process
            # Match the specific inhibitor we created and get its PID
            inhibitor_info=$(systemd-inhibit --list | grep "sleep.*Active SSH")
            if [ ! -z "$inhibitor_info" ]; then
                logger "Found inhibitor: $inhibitor_info"
                # Try to get PID from PID file first
                if [ ! -z "$pid_from_file" ] && kill -0 "$pid_from_file" 2>/dev/null; then
                    logger "Killing sleep inhibitor PID $pid_from_file"
                    kill -9 "$pid_from_file"
                else
                    # Fallback to parsing systemd-inhibit output
                    inhibitor_pid=$(echo "$inhibitor_info" | awk '{print $NF}')
                    if [[ "$inhibitor_pid" =~ ^[0-9]+$ ]]; then
                        logger "Killing sleep inhibitor PID $inhibitor_pid"
                        kill -9 "$inhibitor_pid"
                    else
                        logger "Could not determine valid PID from inhibitor info"
                    fi
                fi
            fi

            # Clean up PID file
            rm -f "$PID_FILE"
        fi
    }

    # Run check every second
    while true; do
        check_sessions
        sleep 1
    done
  '';
in {
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
}
