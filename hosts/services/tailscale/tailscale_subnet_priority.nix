# This script is used to set the routing priority for the Tailscale LAN
# interface. It is run as a systemd service to ensure it runs after
# the Tailscale service is started.
# It checks if the system is on the target network (192.168.1.0/24) and
# adds a routing rule so that packets are routed on the local network and not tailscale.
# this lets us run with --accept-routes=true and have the local network accessible.
# But also lets the laptop roam on other networks.
# This biggest problem I forsee is when we connect to a newtwork in the 192.168.1.0/24 range
# and its not our network. Then things may break. Who knows!
{pkgs, ...}: {
  systemd.services.tailscale-lan-priority = {
    description = "Manage Tailscale LAN routing priorities";
    after = ["network.target" "tailscaled.service"];
    requires = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.iproute2 pkgs.util-linux pkgs.gawk];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = "${pkgs.writeScript "tailscale-lan-priority-start" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        trap 'logger -t tailscale-lan-priority "Error occurred at line $LINENO"; exit 1' ERR

        log_msg() {
          logger -t tailscale-lan-priority "$1"
        }

        # Check if we're on the target network
        if ip -4 addr show | grep -q "192\\.168\\.1\\."; then
          # Add rule only if it doesn't exist
          if ! ip rule show | grep -q "to 192.168.1.0/24 lookup main"; then
            ip rule add to 192.168.1.0/24 priority 2500 lookup main
            log_msg "Added priority rule for home network"
          else
            log_msg "Priority rule already exists"
          fi
        else
          # Remove rule only if it exists
          if ip rule show | grep -q "to 192.168.1.0/24 lookup main"; then
            ip rule del to 192.168.1.0/24 priority 2500 lookup main
            log_msg "Removed priority rule (not on target network)"
          else
            log_msg "No rule to remove"
          fi
        fi
      ''}";

      ExecStop = "${pkgs.writeScript "tailscale-lan-priority-stop" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        trap 'logger -t tailscale-lan-priority "Error occurred at line $LINENO"; exit 1' ERR

        log_msg() {
          logger -t tailscale-lan-priority "$1"
        }

        # Remove rule only if it exists
        if ip rule show | grep -q "to 192.168.1.0/24 lookup main"; then
          ip rule del to 192.168.1.0/24 priority 2500 lookup main
          log_msg "Cleaned up priority rule"
        else
          log_msg "No rule to clean up"
        fi
      ''}";
    };
  };
}
