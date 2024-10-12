{ config, inputs, home, pkgs, ... }:
{
  home.file = {
    ".ssh/authorized_keys".source = ./authorized_keys;
  };
}
