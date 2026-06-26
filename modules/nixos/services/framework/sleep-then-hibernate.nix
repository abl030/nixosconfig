{
  lib,
  config,
  ...
}: let
  cfg = config.homelab.framework.sleepThenHibernate;
in {
  options.homelab.framework.sleepThenHibernate = {
    enable = lib.mkEnableOption "Framework suspend-then-hibernate configuration";
  };

  config = lib.mkIf cfg.enable {
    # Native systemd suspend-then-hibernate configuration
    systemd.sleep.settings.Sleep = {
      AllowSuspendThenHibernate = "yes";
      HibernateDelaySec = "3h";
      SuspendEstimationSec = "1h";
      HibernateOnACPower = "no";
      HibernateMode = "shutdown";
      SuspendState = "freeze";
    };

    # Trigger suspend-then-hibernate on lid close (not plain suspend)
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend-then-hibernate";
      HandleLidSwitchExternalPower = "suspend-then-hibernate";
    };

    # !! LOAD-BEARING: logind MUST own the lid, NOT GNOME. !!
    # Hand the lid to logind (so the HandleLidSwitch above actually fires) by
    # making UPower report "no lid present" → gsd-power skips ALL lid management.
    #
    # Why: GNOME's gsd-power normally takes a low-level `handle-lid-switch` block
    # inhibitor to handle the lid itself. On systemd >=250 that low-level lock is
    # ALWAYS honored — while it's held, logind ignores the lid and HandleLidSwitch
    # is irrelevant. gsd-power 50.x has a bug where an AMD s2idle glitch-wake (a
    # Framework-13-AMD quirk that re-probes displays) makes it latch that inhibitor
    # with a PHANTOM external monitor and never release it → a closed lid silently
    # stops suspending until reboot. No logind setting can override a held low-level
    # lock, so the only real fix is to stop gsd-power taking it.
    #
    # Mechanism: gsd-power gates its entire lid-inhibitor setup on
    # `up_client_get_lid_is_present()` (gsd-power-manager.c: `if (lid_is_present)`
    # around sync_lid_inhibitor()). IgnoreLid=true → lid_is_present=false →
    # gsd-power never wires the monitor handler, never takes the inhibitor; logind
    # then drives lid-close natively via SW_LID + HandleLidSwitch above.
    #
    # DO NOT "fix" lid-suspend by touching LidSwitchIgnoreInhibited — it only
    # governs HIGH-level (sleep/idle) locks and does NOTHING for this. Full RCA:
    # docs/wiki/infrastructure/framework-lid-suspend-gsd-power.md
    services.upower.ignoreLid = true;

    # Clear stale RTC alarms on boot
    systemd.services.clear-rtc-alarm = {
      description = "Clear stale RTC alarms on boot";
      wantedBy = ["multi-user.target"];
      serviceConfig.Type = "oneshot";
      serviceConfig.NoNewPrivileges = true; # echo to sysfs as root; no setuid (#232)
      script = ''
        echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
      '';
    };
  };
}
