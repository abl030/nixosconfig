{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.homelab.ssh;

  # See docs/wiki/services/ssh-sleep-inhibitor.md for why this is opt-in and
  # the failure mode it caused on doc2 (issue #222): every spawned
  # systemd-inhibit holds a UID-0 D-Bus connection until killed; under
  # parallel SSH the previous PID-file bookkeeping leaked them, eventually
  # tripping dbus-broker's max_connections_per_user=256 and wedging the
  # control plane (SSH session setup, systemd-run, switch-to-configuration).
  ssh_script =
    pkgs.writeScript "ssh-session-handler"
    ''
      #!/bin/sh
      # Block sleep targets while any SSH session is open. On last close,
      # kill ALL inhibitors we own — pkill is the bookkeeping; do not try
      # to track PIDs in a file (concurrent opens make it lossy).

      num_ssh=$(${pkgs.nettools}/bin/netstat -nt | ${pkgs.gawk}/bin/awk '$4 ~ /:22$/ && $6 == "ESTABLISHED"' | wc -l)

      case "$PAM_TYPE" in
          open_session)
              [ "$num_ssh" -gt 1 ] && exit 0
              ${pkgs.systemd}/bin/systemd-inhibit \
                  --what=sleep \
                  --why="Active SSH session" \
                  --mode=block \
                  ${pkgs.coreutils}/bin/sleep infinity \
                  0>&- &> /dev/null &
              ;;
          close_session)
              [ "$num_ssh" -ne 0 ] && exit 0
              ${pkgs.procps}/bin/pkill -f 'systemd-inhibit --what=sleep --why=Active SSH session' || true
              ;;
      esac
      exit 0
    '';
in {
  options.homelab.ssh.inhibitors.enable = lib.mkEnableOption ''
    Block sleep/hibernate while an SSH session is open.

    Only meaningful on hosts that actually sleep (laptops/desktops). Servers
    and VMs do not sleep, and enabling this leaks systemd-inhibit processes
    under parallel SSH — see issue #222.
  '';

  config = lib.mkIf (cfg.enable && config.homelab.ssh.inhibitors.enable) {
    security.pam.services.sshd.text = lib.mkDefault (
      lib.mkAfter
      "session optional pam_exec.so quiet ${ssh_script}"
    );
  };
}
