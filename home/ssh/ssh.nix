# At the moment this doesn't work. Because we have a permissions error on the authorized_keys file.
# I can't be bother settings this up in home manager because its super easily done in the nixos config
#Hence this is just going to be left here.
# For home manager managed installs just copy the above authorized_keys file over.
{ config, inputs, home, pkgs, ... }:
{
  home.file = {
    # ".ssh/authorized_keys".source = ./authorized_keys;
    ".ssh/config".source = ./config;
  };
}
