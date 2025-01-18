{ config, pkgs, lib, ... }:

{
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    openFirewall = false;
    # We won't be binding to 0.0.0.0. We will only use this server to proxyjump for X11 forwarding.
    listenAddresses = [
      {
        addr = "0.0.0.0";
      }
    ];
    settings = {
      PasswordAuthentication = true;
      X11Forwarding = true;
      PermitRootLogin = "no";
    };
  };
  imports = [
    ../services/system/ssh_nosleep.nix
    ../services/system/ssh_nosleep_cleanup.nix
  ];
}
