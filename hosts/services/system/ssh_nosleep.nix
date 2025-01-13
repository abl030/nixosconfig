# This expression was written by `cbrauchli` at https://discourse.nixos.org/t/disable-suspend-if-ssh-sessions-are-active/11655/4
# with minor modifications by Dominic Mayhew
# and edited for tailscale by abl030

{ config, lib, pkgs, ... }:

let
  PID_PATH = "/tmp/ssh_sleep_block.pid";
  PID_PIPE = "pid_pipe";

  sleep_script = pkgs.writeScript "infinite-sleep" ''
    #!/bin/sh
    echo $$ >${PID_PATH}
    echo $$ >${PID_PIPE}
    sleep infinity
  '';

  inhibit_script = pkgs.writeScript "inhibit_script" ''
    #!/bin/sh
    systemd-inhibit --what=sleep --why="Active SSH/Tailscale session" --mode=block ${sleep_script} 0>&- &> /tmp/inhibit.out &
  '';

  ssh_script = pkgs.writeScript "ssh-session-handler" ''
    #!/bin/sh
    # This script runs when an ssh/tailscale session opens/closes
    # and handles sleep inhibition
    
    # Count both regular SSH and Tailscale SSH sessions
    num_ssh=$(netstat -nt | awk '$4 ~ /:22$/ && $6 == "ESTABLISHED"' | wc -l)
    
    logger "SSH handler: PAM_TYPE=$PAM_TYPE, num_ssh=$num_ssh, service=$PAM_SERVICE"
    
    case "$PAM_TYPE" in
        open_session)
            if [ "$num_ssh" -gt 1 ]; then
                exit
            fi
            logger "Starting sleep inhibitor for $PAM_SERVICE"
            mkfifo ${PID_PIPE}
            ${inhibit_script}
            logger "Sleep inhibitor started with PID $(cat ${PID_PIPE})"
            rm ${PID_PIPE}
            ;;
        close_session)
            if [ "$num_ssh" -ne 0 ]; then
                exit
            fi
            if [ -f ${PID_PATH} ]; then
                logger "Killing sleep inhibitor PID $(cat ${PID_PATH})"
                kill -9 $(cat ${PID_PATH}) && rm ${PID_PATH}
            fi
            ;;
        *)
            exit
    esac
  '';
in
{
  # Apply to both sshd and login (for Tailscale) PAM services
  security.pam.services = {
    sshd.text = lib.mkDefault (
      lib.mkAfter
        "session optional pam_exec.so quiet ${ssh_script}"
    );

    login.text = lib.mkDefault (
      lib.mkAfter
        "session optional pam_exec.so quiet ${ssh_script}"
    );
  };
}
