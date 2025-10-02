{
  config,
  lib,
  pkgs,
  ...
}: {
  systemd.services.disable-wireless-hibernate = {
    description = "Disable WiFi and Bluetooth before hibernation/sleep";
    wantedBy = [
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend.target"
      "suspend-then-hibernate.target"
    ];
    before = [
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend.target"
      "suspend-then-hibernate.target"
    ];
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

  systemd.services.enable-wireless-resume = {
    description = "Re-enable WiFi and Bluetooth after resume";
    wantedBy = [
      "post-resume.target"
      "post-suspend.target"
    ];
    after = [
      "post-resume.target"
      "post-suspend.target"
    ];
    script = ''
      # Re-enable WiFi
      ${pkgs.networkmanager}/bin/nmcli radio wifi on || true

      # Re-enable Bluetooth
      ${pkgs.bluez}/bin/bluetoothctl power on || true

      systemctl restart bluetooth
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      User = "root";
    };
  };
}
