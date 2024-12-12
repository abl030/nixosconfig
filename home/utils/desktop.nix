{ config, pkgs, ... }:

{
  home.packages = [
    pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.libreoffice-qt
    pkgs.remmina
    #VLC doesn't user VAAPI anymore because devs are fighting over FFMPEG
    #Just use gnome videos for now
    pkgs.vlc
    pkgs.mpv
    pkgs.tailscale-systray
    # pkgs.warp-terminal
    pkgs.alacritty
    pkgs.obs-studio
    pkgs.xfce.thunar
    pkgs.audacity
  ];
}
