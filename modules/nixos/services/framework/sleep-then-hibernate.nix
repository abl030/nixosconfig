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
    systemd.sleep.extraConfig = ''
      AllowSuspendThenHibernate=yes
      HibernateDelaySec=3h
      SuspendEstimationSec=1h
      HibernateOnACPower=no

      HibernateMode=shutdown
      SuspendState=freeze
    '';

    # Trigger suspend-then-hibernate on lid close (not plain suspend)
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend-then-hibernate";
      HandleLidSwitchExternalPower = "suspend-then-hibernate";
    };

    # Clear stale RTC alarms on boot
    systemd.services.clear-rtc-alarm = {
      description = "Clear stale RTC alarms on boot";
      wantedBy = ["multi-user.target"];
      serviceConfig.Type = "oneshot";
      script = ''
        echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
      '';
    };
  };
}
