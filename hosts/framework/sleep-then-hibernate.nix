{ config, pkgs, ... }:
# Old way using a custom systemd service.
# let
#   hibernateEnvironment = {
#     HIBERNATE_SECONDS = "3600";
#     HIBERNATE_LOCK = "/var/run/autohibernate.lock";
#   };
# in
{
  #   systemd.services."awake-after-suspend-for-a-time" = {
  #     description = "Sets up the suspend so that it'll wake for hibernation";
  #     wantedBy = [ "suspend.target" ];
  #     before = [ "systemd-suspend.service" ];
  #     environment = hibernateEnvironment;
  #     script = ''
  #       curtime=$(date +%s)
  #       echo "$curtime $1" >> /tmp/autohibernate.log
  #       echo "$curtime" > $HIBERNATE_LOCK
  #       ${pkgs.utillinux}/bin/rtcwake -m no -s $HIBERNATE_SECONDS
  #     '';
  #     serviceConfig.Type = "simple";
  #   };
  #   systemd.services."hibernate-after-recovery" = {
  #     description = "Hibernates after a suspend recovery due to timeout";
  #     wantedBy = [ "suspend.target" ];
  #     after = [ "systemd-suspend.service" ];
  #     environment = hibernateEnvironment;
  #     script = ''
  #       curtime=$(date +%s)
  #       sustime=$(cat $HIBERNATE_LOCK)
  #       rm $HIBERNATE_LOCK
  #       if [ $(($curtime - $sustime)) -ge $HIBERNATE_SECONDS ] ; then
  #         systemctl hibernate
  #       else
  #         ${pkgs.utillinux}/bin/rtcwake -m no -s 1
  #       fi
  #     '';
  #     serviceConfig.Type = "simple";
  #   };




  # https://gist.github.com/mattdenner/befcf099f5cfcc06ea04dcdd4969a221?permalink_comment_id=5275164#gistcomment-5275164
  # actually lets let systemd do the hibernation for us
  # 
  #
  # There are a couple more lid options in NixOS:
  # https://search.nixos.org/options?channel=24.05&from=0&size=50&sort=relevance&type=packages&query=services.logind.lidSwitch
  #
  # services.logind.lidSwitchExternalPower defaults to what is set for services.logind.lidSwitch so I’m fine with this setting.
  #
  # services.logind.lidSwitchDocked defaults to ignore which I like as well since I’m often docked to an external monitor so this means I can put the lid down and it doesn’t Suspend.

  systemd.sleep.extraConfig = ''
    HibernateDelaySec=60min
  '';
  services.logind.lidSwitch = "suspend-then-hibernate";

}
