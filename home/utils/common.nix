{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.yt-dlp
    pkgs.neofetch
    pkgs.wakeonlan
    pkgs.htop
    # pkgs.nvtopPackages.full
    pkgs.nmap
    pkgs.warp-terminal
  ];
}
