{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kdePackages.dolphin
    # These are our thumbnailers. QT5 because we using LXQT.
    # Use the KDE ones is you are using KDE elsewhere
    pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.libsForQt5.kio-extras
    pkgs.kdePackages.ffmpegthumbs
    pkgs.kdePackages.dolphin-plugins
    pkgs.kdePackages.qtwayland
    pkgs.kdePackages.qtsvg
    pkgs.libsForQt5.qt5ct
    pkgs.zathura
    pkgs.ganttproject-bin
    # pkgs.ghostty

  ];
}
 
