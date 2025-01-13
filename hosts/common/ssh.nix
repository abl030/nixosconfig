{ config, pkgs, lib, ... }:

{
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PasswordAuthentication = true;
      # AllowUsers = null; # Allows all users by default. Can be [ "user1" "user2" ]
      # UseDns = true;
      X11Forwarding = true;
      PermitRootLogin = "no"; # "yes", "without-password", "prohibit-password", "forced-commands-only", "no"
    };
  };
  imports = [
    ../services/system/ssh_nosleep.nix
  ];
}
