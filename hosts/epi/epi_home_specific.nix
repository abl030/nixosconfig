{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.dolphin
    # These are our thumbnailers. QT5 because we using LXQT.
    # Use the KDE ones is you are using KDE elsewhere
    pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.libsForQt5.kio-extras
    pkgs.ffmpegthumbs
    pkgs.kdePackages.dolphin-plugins
    pkgs.kdePackages.qtwayland
    pkgs.kdePackages.qtsvg
    pkgs.libsForQt5.qt5ct

  ];
}
 
