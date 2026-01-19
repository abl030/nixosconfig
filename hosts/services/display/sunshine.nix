{
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = lib.mkOrder 2200 (with pkgs; [
    sunshine
    moonlight-qt #for testing purposes.
  ]);

  # security.wrappers.sunshine = {
  #   owner = "root";
  #   group = "root";
  #   capabilities = "cap_sys_admin+p";
  #   source = "${pkgs.sunshine}/bin/sunshine";
  # };
  #
  # Group all service definitions under a single `services` attribute set to avoid repetition.
  services = {
    sunshine = {
      enable = true;
      autoStart = true;
      capSysAdmin = true;
      openFirewall = true;
    };
    avahi.publish = {
      enable = true;
      userServices = true;
    };
  };

  boot.kernelModules = ["uinput"];

  # networking.firewall = {
  #   enable = true;
  #   allowedTCPPorts = [ 47984 47989 47990 48010 ];
  #   allowedUDPPortRanges = [
  #     { from = 47998; to = 48000; }
  #     #{ from = 8000; to = 8010; }
  #   ];
  # };
  #
  # systemd.user.services.sunshine = {
  #   description = "Sunshine self-hosted game stream host for Moonlight";
  #   startLimitBurst = 5;
  #   startLimitIntervalSec = 500;
  #   wantedBy = [ "default.target" ]; # Ensure it's enabled and started
  #   serviceConfig = {
  #     ExecStart = "${config.security.wrapperDir}/sunshine";
  #     Restart = "on-failure";
  #     RestartSec = "5s";
  #   };
  # };
  #
}
