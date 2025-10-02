{
  config,
  pkgs,
  inputs,
  ...
}: {
  home.packages = [
    # pkgs.kitty
    pkgs.plexamp
    pkgs.google-chrome
    pkgs.libreoffice-qt
    pkgs.hunspell
    pkgs.hunspellDicts.en_AU
    pkgs.hunspellDicts.en_GB-ise
    # This is for the libreoffice zotero connector.
    pkgs.temurin-jre-bin-17
    pkgs.remmina
    #VLC doesn't user VAAPI anymore because devs are fighting over FFMPEG
    #Just use gnome videos for now
    # pkgs.vlc
    pkgs.mpv
    pkgs.tailscale-systray
    # pkgs.warp-terminal
    # pkgs.alacritty
    pkgs.obs-studio
    # # pkgs.xfce.thunar
    # pkgs.audacity
    #This builds wezterm from source
    # inputs.wezterm.packages.${pkgs.system}.default
    pkgs.galaxy-buds-client
    pkgs.freetube
    pkgs.zotero-beta
    # pkgs.linuxKernel.packages.linux_latest_libre.turbostat
    pkgs.neovide
    pkgs.ffmpeg
    pkgs.zathura
    pkgs.moonlight-qt
    pkgs.popsicle
    pkgs.pinta
    pkgs.usbutils
    # pkgs.pulseaudioFull
  ];

  imports = [
    ../terminals/ghostty/ghostty.nix
    ../utils/vscode.nix
  ];
}
