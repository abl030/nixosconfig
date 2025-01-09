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
    pkgs.unzip
    pkgs.nvd
    # Rust Utils
    pkgs.fzf
    pkgs.lsd
    pkgs.zoxide
    pkgs.broot
    pkgs.ripgrep
    pkgs.ripgrep-all
    pkgs.toybox
  ];
}
