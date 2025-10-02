{
  config,
  lib,
  pkgs,
  ...
}: let
  PID_PATH = "/tmp/rdp_sleep_block.pid";
  PID_PIPE = "rdp_pid_pipe";

  sleep_script = pkgs.writeScript "rdp-infinite-sleep" ''
    #!/bin/sh
    echo $$ >${PID_PATH}
    echo $$ >${PID_PIPE}
    sleep infinity
  '';

  inhibit_script = pkgs.writeScript "rdp-inhibit_script" ''
    #!/bin/sh
    systemd-inhibit --what=sleep --why="Active Remote Desktop session" --mode=block ${sleep_script} 0>&- &> /tmp/rdp_inhibit.out &
  '';

  rdp_monitor_script = pkgs.writeScript "rdp-session-monitor" ''
    #!${pkgs.bash}/bin/bash

    check_rdp_sessions() {
      # Check for active gnome-remote-desktop sessions (both port 3389 and 3390)
      num_rdp=$(${pkgs.nettools}/bin/netstat -nt | ${pkgs.gawk}/bin/awk '$4 ~ /:3389$/ || $4 ~ /:3390$/ && $6 == "ESTABLISHED"' | wc -l)
      echo $num_rdp
    }

    cleanup() {
      if [ -f ${PID_PATH} ]; then
        ${pkgs.utillinux}/bin/logger "RDP Monitor: Cleaning up sleep inhibitor PID $(cat ${PID_PATH})"
        kill -9 $(cat ${PID_PATH}) 2>/dev/null
        rm -f ${PID_PATH}
      fi
      exit 0
    }

    trap cleanup SIGTERM SIGINT

    while true; do
      num_sessions=$(check_rdp_sessions)

      if [ "$num_sessions" -gt 0 ]; then
        if [ ! -f ${PID_PATH} ]; then
          ${pkgs.utillinux}/bin/logger "RDP Monitor: Starting sleep inhibitor for Remote Desktop session"
          mkfifo ${PID_PIPE}
          ${inhibit_script}
          ${pkgs.utillinux}/bin/logger "RDP Monitor: Sleep inhibitor started with PID $(cat ${PID_PIPE})"
          rm -f ${PID_PIPE}
        fi
      else
        if [ -f ${PID_PATH} ]; then
          ${pkgs.utillinux}/bin/logger "RDP Monitor: Killing sleep inhibitor PID $(cat ${PID_PATH})"
          kill -9 $(cat ${PID_PATH}) 2>/dev/null
          rm -f ${PID_PATH}
        fi
      fi

      sleep 10
    done
  '';
in {
  systemd.services.rdp-sleep-inhibit = {
    description = "GNOME Remote Desktop Sleep Inhibitor";
    after = ["network.target" "gnome-remote-desktop.service"];
    wantedBy = ["multi-user.target"];

    path = with pkgs; [
      nettools
      gawk
      utillinux
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${rdp_monitor_script}";
      Restart = "always";
      RestartSec = "10";
    };
  };
}
