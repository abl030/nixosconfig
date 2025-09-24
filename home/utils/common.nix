{ config, pkgs, inputs, ... }:

{
  home.packages = [
    pkgs.yt-dlp
    pkgs.deno
    pkgs.neofetch
    pkgs.wakeonlan
    pkgs.htop
    pkgs.btop
    pkgs.nmap
    pkgs.television
    pkgs.wget
    pkgs.pciutils
    pkgs.fish
    pkgs.unzip
    pkgs.nvd
    pkgs.speedtest-cli
    pkgs.lazydocker
    pkgs.bind.dnsutils
    pkgs.lazygit
    pkgs.gnome-disk-utility
    pkgs.ansible
    pkgs.tldr

    # Rust Utils
    pkgs.fzf
    pkgs.lsd
    pkgs.zoxide
    pkgs.broot
    pkgs.ripgrep
    pkgs.ripgrep-all

    # pkgs.toybox
    # pkgs.zip
    # pkgs.busybox
    inputs.fzf-preview.packages.${pkgs.system}.default
    inputs.isd.packages.${pkgs.system}.default
  ];
  imports = [
    # ../ssh/ssh.nix
  ];
}
