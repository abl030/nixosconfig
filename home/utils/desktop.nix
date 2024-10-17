{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.dolphin
    pkgs.libreoffice-qt
    # pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.kdePackages.kdegraphics-thumbnailers
    pkgs.kdePackages.kdesdk-thumbnailers
  ];
}
