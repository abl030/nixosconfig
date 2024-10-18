{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.libreoffice-qt
    pkgs.remmina
    pkgs.dolphin
    # pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.kdePackages.kdegraphics-thumbnailers
    pkgs.kdePackages.kdesdk-thumbnailers

  ];
}
