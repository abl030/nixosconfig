{ config, pkgs, lib, ... }:

let
  PID_PATH = "/tmp/rdp_sleep_block.pid";
  PID_PIPE = "rdp_pid_pipe";

  # Script to prevent sleep
  sleep_script_rdp = pkgs.writeScript "rdp-infinite-sleep" ''
    #!/bin/sh
    echo $$ >${PID_PATH}
    echo $$ >${PID_PIPE}
    sleep infinity
  '';

  # Script to inhibit sleep during active RDP sessions
  inhibit_script_rdp = pkgs.writeScript "rdp-inhibit-script" ''
    #!/bin/sh
    systemd-inhibit --what=sleep --why="Active RDP session" --mode=block ${sleep_script_rdp} 0>&- &> /tmp/rdp_inhibit.out &
  '';

  # Script to manage RDP session lifecycle
  rdp_script = pkgs.writeScript "rdp-session-handler" ''
    #!/bin/sh
    num_rdp=$(netstat -nt | awk '($4 ~ /:3389$/ || $4 ~ /:3390$/) && $6 == "ESTABLISHED"' | wc -l)

    case "$PAM_TYPE" in
      open_session)
        if [ "$num_rdp" -gt 1 ]; then
          exit
        fi
        logger "Starting RDP sleep inhibitor"
        mkfifo ${PID_PIPE}
        ${inhibit_script_rdp}
        logger "RDP sleep inhibitor started with PID $(cat ${PID_PIPE})"
        rm ${PID_PIPE}
        ;;
      close_session)
        if [ "$num_rdp" -ne 0 ]; then
          exit
        fi
        logger "Killing RDP sleep inhibitor PID $(cat ${PID_PATH})"
        kill -9 $(cat ${PID_PATH}) && rm ${PID_PATH}
        ;;
      *)
        exit
    esac
  '';
in
{
  # Add the script to PAM for GNOME Remote Desktop sessions
  security.pam.services.gnome-remote-desktop.text = pkgs.lib.mkDefault (
    pkgs.lib.mkAfter
      "# Prevent sleep on active RDP sessions\nsession optional pam_exec.so quiet ${rdp_script}"
  );
}

