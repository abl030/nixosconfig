{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    pkgs.sunshine
    pkgs.moonlight-qt #for testing purposes.
  ];

  # security.wrappers.sunshine = {
  #   owner = "root";
  #   group = "root";
  #   capabilities = "cap_sys_admin+p";
  #   source = "${pkgs.sunshine}/bin/sunshine";
  # };
  #
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
  };

  services.avahi.publish.enable = true;
  services.avahi.publish.userServices = true;

  boot.kernelModules = [ "uinput" ];

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
