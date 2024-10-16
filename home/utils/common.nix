{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.yt-dlp
    pkgs.neofetch
    pkgs.wakeonlan
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
  ];
}
