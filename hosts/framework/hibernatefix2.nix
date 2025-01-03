{ config, lib, pkgs, ... }:

{
  systemd.services.disable-wireless-hibernate = {
    description = "Disable WiFi and Bluetooth before hibernation";
    wantedBy = [ "hibernate.target" "hybrid-sleep.target" ];
    before = [ "hibernate.target" "hybrid-sleep.target" ];
    script = ''
      # Disable WiFi
      ${pkgs.networkmanager}/bin/nmcli radio wifi off || true
      
      # Disable Bluetooth
      ${pkgs.bluez}/bin/bluetoothctl power off || true
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      User = "root";
    };
  };

  # Optional: Create a complementary service to re-enable on resume
  systemd.services.enable-wireless-resume = {
    description = "Re-enable WiFi and Bluetooth after resume";
    wantedBy = [ "post-resume.target" ];
    after = [ "post-resume.target" ];
    script = ''
      # Re-enable WiFi
      ${pkgs.networkmanager}/bin/nmcli radio wifi on || true
      
      # Re-enable Bluetooth
      ${pkgs.bluez}/bin/bluetoothctl power on || true
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      User = "root";
    };
  };
}
