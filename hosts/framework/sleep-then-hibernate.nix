{
  pkgs,
  config,
  ...
}: let
  # === CONFIGURATION ===
  checkIntervalSeconds = "3600"; # Wake up every hour to check status
  settleDownSeconds = "20"; # Wait time to prevent GPU/NVMe panic before Hibernate

  # === LOGGING HELPER ===
  # Logs to journalctl with tag "PowerSentry".
  # Usage: journalctl -t PowerSentry
  log = msg: "${pkgs.util-linux}/bin/logger -t PowerSentry \"${msg}\"";

  # === POWER CHECK HELPER ===
  # Returns 0 (true) if plugged in, 1 (false) if on battery
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
  # 1. DISABLE SYSTEMD AUTO-HIBERNATION
  # We are taking full manual control.
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=0
  '';

  services.logind.settings = {
    Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "suspend";
    };
  };

  # 2. BEFORE SUSPEND: Set the Alarm
  systemd.services."suspend-set-timer" = {
    description = "Sets RTC wake timer for 1 hour check";
    wantedBy = ["suspend.target"];
    before = ["systemd-suspend.service"];
    script = ''
      # 1. Clear old alarms
      ${pkgs.util-linux}/bin/rtcwake -m disable

      # 2. Record suspend time
      date +%s > /tmp/last_suspend_time

      # 3. Log intention
      ${log "System suspending. Setting RTC wake alarm for ${checkIntervalSeconds} seconds."}

      # 4. Set alarm for 1 hour
      ${pkgs.util-linux}/bin/rtcwake -m no -s ${checkIntervalSeconds}
    '';
    serviceConfig.Type = "oneshot";
  };

  # 3. AFTER RESUME: The Decision Matrix
  systemd.services."suspend-wake-handler" = {
    description = "Checks if we should Hibernate, Sleep again, or Stay Awake";
    wantedBy = ["suspend.target"];
    after = ["systemd-suspend.service"];
    script = ''
      # Safety check: if time file missing, assume manual wake
      if [ ! -f /tmp/last_suspend_time ]; then
        ${log "Wake detected, but no timestamp found. Assuming manual wake."}
        exit 0
      fi

      suspend_time=$(cat /tmp/last_suspend_time)
      current_time=$(date +%s)
      elapsed=$((current_time - suspend_time))
      rm /tmp/last_suspend_time

      # Allow for 5 seconds variance in wake time execution
      threshold=$((${checkIntervalSeconds} - 5))

      ${log "System woke up. Slept for $elapsed seconds."}

      if [ "$elapsed" -ge "$threshold" ]; then
        # === SCENARIO: TIMER WOKE US UP ===
        if ${isPluggedIn}; then
          # --- PATH A: PLUGGED IN ---
          ${log "Timer wake caused by RTC. Power: AC DETECTED. Action: Re-suspending loop."}

          # We don't need to manually set the alarm here because
          # 'systemctl suspend' will trigger 'suspend-set-timer' again automatically.
          systemctl suspend
        else
          # --- PATH B: BATTERY ---
          ${log "Timer wake caused by RTC. Power: BATTERY DETECTED. Action: Hibernating."}

          # === THE CRASH FIX ===
          ${log "Waiting ${settleDownSeconds}s for AMDGPU/NVMe to stabilize..."}
          sleep ${settleDownSeconds}

          ${log "Hardware settled. Triggering hibernation."}
          systemctl hibernate
        fi
      else
        # === SCENARIO: USER WOKE US UP ===
        ${log "Wake was manual (Lid/Keyboard). Cancelled auto-hibernate logic."}
        ${pkgs.util-linux}/bin/rtcwake -m disable
      fi
    '';
    serviceConfig.Type = "oneshot";
  };
}
