{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.libreoffice-qt
    pkgs.remmina
    pkgs.vlc
    pkgs.tailscale-systray
    pkgs.warp-terminal
    pkgs.alacritty
    pkgs.obs-studio
    pkgs.xfce.thunar
    pkgs.audacity
  ];
}
