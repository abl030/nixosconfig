{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.libreoffice-qt
    pkgs.remmina
    pkgs.vlc

  ];
}
