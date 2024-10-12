{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.yt-dlp
    pkgs.neofetch
    pkgs.wakeonlan
  ];
}
