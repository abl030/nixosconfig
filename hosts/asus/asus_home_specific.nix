{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.dolphin
    # pkgs.libsForQt5.kdegraphics-thumbnailers
    pkgs.kdePackages.kdegraphics-thumbnailers
    pkgs.kdePackages.kdesdk-thumbnailers
  ];
}
