{pkgs, ...}: let
  # === CONFIGURATION ===
  checkIntervalSeconds = "10800"; # Wake every 3 hours to check status
  settleDownSeconds = "20"; # Wait for GPU/NVMe before hibernate
  upgradeGracePeriod = "1800"; # Wait up to 30 min for upgrade service

  log = msg: "${pkgs.util-linux}/bin/logger -t PowerSentry \"${msg}\"";

  isPluggedIn = pkgs.writeShellScript "check-ac-power" ''
    for supply in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
      if [ -f "$supply/online" ]; then
        status=$(cat "$supply/online")
        if [ "$status" -eq 1 ]; then
          exit 0 # Plugged in
        fi
      fi
    done
    exit 1 # On Battery
  '';
in {
  systemd = {
    sleep.extraConfig = ''
      HibernateDelaySec=0
    '';

    services = {
      "suspend-set-timer" = {
        description = "Sets RTC wake timer for periodic power check";
        wantedBy = ["suspend.target"];
        before = ["systemd-suspend.service"];
        # DON'T run when hibernating - this was causing the loop!
        unitConfig.ConditionPathExists = "!/run/systemd/hibernate";
        script = ''
          ${pkgs.util-linux}/bin/rtcwake -m disable
          date +%s > /tmp/last_suspend_time
          ${log "System suspending. Setting RTC wake alarm for ${checkIntervalSeconds} seconds (3 hours)."}
          ${pkgs.util-linux}/bin/rtcwake -m no -s ${checkIntervalSeconds}
        '';
        serviceConfig.Type = "oneshot";
      };

      "suspend-wake-handler" = {
        description = "Decides: Hibernate, Sleep again, or Stay Awake";
        wantedBy = ["suspend.target"];
        after = ["systemd-suspend.service"];
        script = ''
          # --- HELPER: Check if upgrade service needs to run ---
          check_upgrade_service() {
            # If upgrade service is active/activating, wait for it
            if systemctl is-active --quiet nixos-upgrade.service 2>/dev/null; then
              return 0
            fi
            # Check if it's scheduled to start soon (within grace period)
            if systemctl is-enabled --quiet nixos-upgrade.timer 2>/dev/null; then
              NEXT_RUN=$(systemctl show nixos-upgrade.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")
              if [ -n "$NEXT_RUN" ] && [ "$NEXT_RUN" != "n/a" ]; then
                NEXT_EPOCH=$((NEXT_RUN / 1000000))
                NOW_EPOCH=$(date +%s)
                DIFF=$((NEXT_EPOCH - NOW_EPOCH))
                # If upgrade is scheduled within 5 minutes, let it run
                if [ "$DIFF" -ge 0 ] && [ "$DIFF" -le 300 ]; then
                  return 0
                fi
              fi
            fi
            return 1
          }

          # --- MAIN LOGIC ---
          if [ ! -f /tmp/last_suspend_time ]; then
            ${log "Wake detected, but no timestamp found. Assuming manual wake."}
            exit 0
          fi

          suspend_time=$(cat /tmp/last_suspend_time)
          current_time=$(date +%s)
          elapsed=$((current_time - suspend_time))
          rm -f /tmp/last_suspend_time

          # Allow 60 seconds variance (for 3-hour interval, be more lenient)
          threshold=$((${checkIntervalSeconds} - 60))

          ${log "System woke up. Slept for $elapsed seconds."}

          # Was this wake from our timer, or from something else (upgrade timer, user)?
          if [ "$elapsed" -ge "$threshold" ]; then
            # === TIMER WAKE (from our RTC alarm) ===
            if ${isPluggedIn}; then
              ${log "Timer wake (RTC). Power: AC. Action: Re-suspending."}
              systemctl suspend
            else
              ${log "Timer wake (RTC). Power: BATTERY. Action: Hibernating."}
              ${log "Waiting ${settleDownSeconds}s for hardware to stabilize..."}
              sleep ${settleDownSeconds}
              ${log "Hardware settled. Triggering hibernation."}
              # Clear any stale RTC alarms before hibernating
              ${pkgs.util-linux}/bin/rtcwake -m disable
              systemctl hibernate
            fi
          else
            # === EARLY WAKE (upgrade timer, user, or other source) ===
            ${log "Early wake detected (slept $elapsed s, expected ~${checkIntervalSeconds} s)."}
            ${pkgs.util-linux}/bin/rtcwake -m disable

            if ${isPluggedIn}; then
              ${log "Power: AC. Checking if nixos-upgrade needs to run..."}

              # Wait for upgrade service if it's running or about to run
              if check_upgrade_service; then
                ${log "Upgrade service active/scheduled. Waiting up to ${upgradeGracePeriod}s for completion..."}
                for i in $(seq 1 ${upgradeGracePeriod}); do
                  if ! systemctl is-active --quiet nixos-upgrade.service 2>/dev/null; then
                    break
                  fi
                  sleep 1
                done
                ${log "Upgrade service finished or timed out. Returning to suspend."}
              else
                ${log "No upgrade activity. Returning to suspend."}
              fi
              systemctl suspend
            else
              ${log "Power: BATTERY. Early wake on battery - hibernating immediately."}
              sleep ${settleDownSeconds}
              systemctl hibernate
            fi
          fi
        '';
        serviceConfig.Type = "oneshot";
      };
    };
  };

  services.logind.settings = {
    Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "suspend";
    };
  };
}
