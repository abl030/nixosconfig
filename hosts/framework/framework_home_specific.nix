{pkgs, ...}: {
  home.packages = [
    # pkgs.dolphin
    pkgs.kdePackages.dolphin
    # These are our thumbnailers. QT5 because we using LXQT.
    # Use the KDE ones is you are using KDE elsewhere
    # pkgs.libsForQt5.kdegraphics-thumbnailers
    # pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.kdePackages.kdegraphics-thumbnailers
    # pkgs.libsForQt5.kio-extras
    pkgs.kdePackages.kio-extras
    pkgs.kdePackages.ffmpegthumbs
    pkgs.kdePackages.dolphin-plugins
    pkgs.kdePackages.qtwayland
    pkgs.kdePackages.qtsvg
    pkgs.libsForQt5.qt5ct
    pkgs.spotify
    pkgs.nvtopPackages.amd
    pkgs.acpi
  ];
}
