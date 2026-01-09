{pkgs, ...}: {
  # ============================================================================
  # NATIVE SYSTEMD SUSPEND-THEN-HIBERNATE
  # ============================================================================
  #
  # This replaces all custom rtcwake logic with systemd's built-in handling.
  #
  # Behavior:
  # - Lid close → suspend-then-hibernate
  # - After 3 hours suspended → hibernate (saves battery)
  # - Manual wake (open lid) → stay awake (no more loops!)
  # - Scheduled wake (nixos-upgrade) → handled separately by its own timer
  #
  # Why this fixes your issues:
  # 1. Re-suspend loops: systemd internally tracks whether wake was from
  #    timer vs user action. User wakes cancel the hibernate timer.
  # 2. First-boot issue: clear-rtc-alarm service removes stale alarms
  #    left over from previous sessions.
  #
  # AC Power Note:
  # HibernateOnACPower=no requires systemd v257+. Check with:
  #   systemctl --version
  # On older versions, system hibernates after 3h even on AC. If this
  # bothers you, upgrade NixOS or wait for v257 to land.
  #
  # ============================================================================

  systemd.sleep.extraConfig = ''
    AllowSuspendThenHibernate=yes
    HibernateDelaySec=3h
    SuspendEstimationSec=1h
    HibernateOnACPower=no
  '';

  # Trigger suspend-then-hibernate on lid close (not plain suspend)
  services.logind = {
    lidSwitch = "suspend-then-hibernate";
    lidSwitchExternalPower = "suspend-then-hibernate";
  };

  # FIX: Clear stale RTC alarms on boot
  # This is the key fix for "first suspend immediately hibernates"
  systemd.services.clear-rtc-alarm = {
    description = "Clear stale RTC alarms on boot";
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    script = ''
      echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
    '';
  };
}
