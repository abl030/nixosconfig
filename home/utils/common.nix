{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.yt-dlp
    pkgs.neofetch
    pkgs.wakeonlan
    pkgs.htop
    pkgs.nmap
    pkgs.television
    pkgs.wget
    pkgs.pciutils
    pkgs.fish
  ];
}
