{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.homelab.tailscale;
  localRules = [
    {
      cidr = "192.168.1.0/24";
      priority = "2500";
      label = "home network";
      onlyOnLan = true;
    }
    {
      cidr = "192.168.100.0/24";
      priority = "2490";
      label = "local nspawn service network";
      onlyOnLan = false;
    }
  ];
  ruleScript =
    lib.concatMapStringsSep "\n" (rule: ''
      manage_rule "${rule.cidr}" "${rule.priority}" "${rule.label}" "${toString rule.onlyOnLan}"
    '')
    localRules;
  cleanupScript =
    lib.concatMapStringsSep "\n" (rule: ''
      remove_rule "${rule.cidr}" "${rule.priority}" "${rule.label}"
    '')
    localRules;
in {
  config = lib.mkIf cfg.enable {
    systemd.services.tailscale-lan-priority = {
      description = "Manage Tailscale LAN routing priorities";
      after = ["network.target" "tailscaled.service"];
      requires = ["tailscaled.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.iproute2 pkgs.util-linux pkgs.gawk];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";

        ExecStart = "${pkgs.writeScript "tailscale-lan-priority-start" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          trap 'logger -t tailscale-lan-priority "Error occurred at line $LINENO"; exit 1' ERR

          log_msg() {
            logger -t tailscale-lan-priority "$1"
          }

          on_lan() {
            ip -4 addr show | grep -q "192\\.168\\.1\\."
          }

          add_rule() {
            local cidr="$1"
            local priority="$2"
            local label="$3"

            if ! ip rule show | grep -q "to $cidr lookup main"; then
              ip rule add to "$cidr" priority "$priority" lookup main
              log_msg "Added priority rule for $label"
            fi
          }

          remove_rule() {
            local cidr="$1"
            local priority="$2"
            local label="$3"

            if ip rule show | grep -q "to $cidr lookup main"; then
              ip rule del to "$cidr" priority "$priority" lookup main
              log_msg "Removed priority rule for $label"
            fi
          }

          manage_rule() {
            local cidr="$1"
            local priority="$2"
            local label="$3"
            local only_on_lan="$4"

            if [[ "$only_on_lan" == "true" ]] && ! on_lan; then
              remove_rule "$cidr" "$priority" "$label"
            else
              add_rule "$cidr" "$priority" "$label"
            fi
          }

          apply_rules() {
            ${ruleScript}
          }

          apply_rules
          log_msg "Initial rules applied; watching for address changes"

          # Re-evaluate on every interface address change so roaming laptops
          # (e.g. framework leaving home WiFi) don't leave stale rules that
          # shadow tailnet subnet routes. Re-apply is idempotent.
          ip monitor address | while read -r _; do
            apply_rules
          done
        ''}";

        ExecStop = "${pkgs.writeScript "tailscale-lan-priority-stop" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          trap 'logger -t tailscale-lan-priority "Error occurred at line $LINENO"; exit 1' ERR

          log_msg() {
            logger -t tailscale-lan-priority "$1"
          }

          remove_rule() {
            local cidr="$1"
            local priority="$2"
            local label="$3"

            if ip rule show | grep -q "to $cidr lookup main"; then
              ip rule del to "$cidr" priority "$priority" lookup main
              log_msg "Cleaned up priority rule for $label"
            else
              log_msg "No priority rule for $label to clean up"
            fi
          }

          ${cleanupScript}
        ''}";
      };
    };
  };
}
