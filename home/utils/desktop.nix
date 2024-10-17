{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
  ];
}
