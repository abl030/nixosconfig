{
  pkgs,
  lib,
  config,
  ...
}:
# Manage `ip rule` priorities so a host reaches the home LAN (192.168.1.0/24)
# and the local nspawn service network (10.20.0.0/24) via the *main* table
# instead of Tailscale's table 52, but ONLY when it makes sense to.
#
# The 192.168.1.0/24 rule is `onlyOnLan`: a roaming laptop must drop it when
# away so traffic to home hosts (e.g. the nix cache at 192.168.1.29) follows
# the tailnet subnet route Tower advertises (192.168.0.0/23) instead of leaking
# out the foreign default gateway. The whole module exists to keep that one rule
# correct as the laptop roams. See:
#   docs/wiki/infrastructure/nfs-over-tailscale.md  § LAN-vs-Tailscale routing
#   docs/wiki/infrastructure/tailscale-lan-priority.md  (design + incident history)
let
  cfg = config.homelab.tailscale;

  # --- Home-LAN identity ---------------------------------------------------
  # We are "physically on the home LAN" iff the home gateway resolves to
  # pfSense's known LAN MAC in the neighbour table. This is bulletproof against
  # the two false-positive classes that stranded the home rule twice before:
  #   (a) docker/nspawn/veth bridges that carry a 192.168.1.x address, and
  #   (b) foreign networks (hotels/cafes) that reuse 192.168.1.0/24 — their
  #       gateway has a different MAC, so on_lan stays false and the tailnet
  #       route to the *real* home subnet is preserved.
  # Chosen over address-presence detection (see git log: 8d1d8376 -> 2f876028 ->
  # this) and the wiki incident note above.
  homeGatewayIp = "192.168.1.1";
  homeGatewayMac = "64:62:66:21:dd:cc"; # pfSense LAN interface; re-verify if its NIC changes

  lockFile = "/run/tailscale-lan-priority.lock";

  localRules = [
    {
      cidr = "192.168.1.0/24"; # contains homeGatewayIp
      priority = "2500";
      label = "home network";
      onlyOnLan = true;
    }
    {
      cidr = "10.20.0.0/24";
      priority = "2490";
      label = "local nspawn service network";
      onlyOnLan = false;
    }
  ];

  manageCalls =
    lib.concatMapStringsSep "\n" (rule: ''
      manage_rule "${rule.cidr}" "${rule.priority}" "${rule.label}" "${lib.boolToString rule.onlyOnLan}"
    '')
    # NOTE: lib.boolToString, NOT toString. `toString true` is "1" and
    # `toString false` is "" in Nix — the bash guard checks `= "true"`, so
    # toString silently disabled the remove path (manage_rule always fell to
    # add_rule). This was the latent root cause of the stranded-rule bug.
    localRules;

  cleanupCalls =
    lib.concatMapStringsSep "\n" (rule: ''
      remove_rule "${rule.cidr}" "${rule.priority}" "${rule.label}"
    '')
    localRules;

  # Functions shared by the apply pass and the ExecStop cleanup, so the
  # remove/log logic lives in exactly one place. Logs go to stderr (not
  # `logger`) so events land in the unit's own journal — `journalctl -u
  # tailscale-lan-priority*` shows them, instead of only under a syslog tag.
  commonFns = ''
    log_msg() { echo "tailscale-lan-priority: $1" >&2; }

    remove_rule() {
      local cidr="$1" priority="$2" label="$3"
      if ip rule show | grep -q "to $cidr lookup main"; then
        ip rule del to "$cidr" priority "$priority" lookup main
        log_msg "Removed priority rule for $label"
      fi
    }
  '';

  # One idempotent reconcile pass. Invoked by BOTH the event watcher (on every
  # netlink address change) and the reconcile timer (every 30s). A flock
  # serialises the two triggers so concurrent `ip rule` add/del can't race.
  applyScript = pkgs.writeShellApplication {
    name = "tailscale-lan-priority-apply";
    runtimeInputs = [pkgs.iproute2 pkgs.gnugrep pkgs.util-linux];
    text = ''
      exec 9>"${lockFile}"
      flock 9

      ${commonFns}

      on_lan() {
        ip neigh show "${homeGatewayIp}" 2>/dev/null \
          | grep -qi "lladdr ${homeGatewayMac}"
      }

      add_rule() {
        local cidr="$1" priority="$2" label="$3"
        if ! ip rule show | grep -q "to $cidr lookup main"; then
          ip rule add to "$cidr" priority "$priority" lookup main
          log_msg "Added priority rule for $label"
        fi
      }

      manage_rule() {
        local cidr="$1" priority="$2" label="$3" only_on_lan="$4"
        if [ "$only_on_lan" = "true" ] && ! on_lan; then
          remove_rule "$cidr" "$priority" "$label"
        else
          add_rule "$cidr" "$priority" "$label"
        fi
      }

      ${manageCalls}
    '';
  };

  # Fast-reaction watcher. The reconcile timer is the real convergence
  # guarantee, so this only needs to react to address changes and restart if
  # the monitor dies — it carries no periodic logic and no exit-code juggling.
  watchScript = pkgs.writeShellApplication {
    name = "tailscale-lan-priority-watch";
    runtimeInputs = [pkgs.iproute2];
    text = ''
      apply=${lib.getExe applyScript}

      # React to current state immediately, then on every address change.
      "$apply" || echo "tailscale-lan-priority: initial apply failed (transient)" >&2
      while read -r _; do
        "$apply" || echo "tailscale-lan-priority: apply failed (transient)" >&2
      done < <(ip monitor address)

      # ip monitor closed (netlink reset, suspend/resume). Exit non-zero so
      # systemd restarts us and re-establishes the monitor. StartLimitIntervalSec=0
      # means we never give up; the reconcile timer keeps rules correct meanwhile.
      echo "tailscale-lan-priority: ip monitor exited; restarting" >&2
      exit 1
    '';
  };

  cleanupScript = pkgs.writeShellApplication {
    name = "tailscale-lan-priority-cleanup";
    runtimeInputs = [pkgs.iproute2 pkgs.gnugrep pkgs.util-linux];
    text = ''
      exec 9>"${lockFile}"
      flock 9
      ${commonFns}
      ${cleanupCalls}
    '';
  };
in {
  config = lib.mkIf cfg.enable {
    # Event watcher: fast reaction to roaming.
    systemd.services.tailscale-lan-priority = {
      description = "Watch address changes and manage Tailscale LAN routing priorities";
      after = ["network.target" "tailscaled.service"];
      requires = ["tailscaled.service"];
      wantedBy = ["multi-user.target"];

      # Never give up restarting. If the watcher died for good the laptop would
      # be left with whatever rule state it last had until reboot; the reconcile
      # timer is the safety net but the watcher must also stay alive.
      unitConfig.StartLimitIntervalSec = 0;

      serviceConfig = {
        Type = "simple";
        NoNewPrivileges = true; # `ip route/rule` as root; no setuid exec (#232)
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = lib.getExe watchScript;
        ExecStop = lib.getExe cleanupScript;
      };
    };

    # Periodic reconcile, decoupled from the watcher's liveness. The previous
    # design folded reconcile into the watch loop's read-timeout, which never
    # fired once the monitor pipe closed — a dead/flapping monitor could strand
    # a stale rule indefinitely. An independent timer cannot be starved that way.
    systemd.services.tailscale-lan-priority-reconcile = {
      description = "Reconcile Tailscale LAN routing priorities (periodic safety net)";
      after = ["network.target" "tailscaled.service"];
      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true; # `ip route/rule` as root; no setuid exec (#232)
        ExecStart = lib.getExe applyScript;
      };
    };
    systemd.timers.tailscale-lan-priority-reconcile = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };
  };
}
