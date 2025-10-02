{
  hostname,
  config,
  pkgs,
  ...
}: {
  home.packages = [
    pkgs.gnome-tweaks
    pkgs.gnomeExtensions.dash-to-panel
    pkgs.gnomeExtensions.bluetooth-quick-connect
    pkgs.gnomeExtensions.blur-my-shell
    pkgs.gnomeExtensions.tray-icons-reloaded
    pkgs.gnomeExtensions.user-themes
    pkgs.dracula-theme
    pkgs.gnomeExtensions.freon
    pkgs.gnomeExtensions.just-perfection
    pkgs.gnomeExtensions.caffeine
    pkgs.gnomeExtensions.grand-theft-focus
    pkgs.dconf2nix
    pkgs.kdePackages.qtwayland
    pkgs.gnomeExtensions.paperwm
    pkgs.gnomeExtensions.allow-locked-remote-desktop
    pkgs.gnomeExtensions.system-monitor
  ];

  imports = [
    # ./gnome_configs/${hostname}.nix
  ];

  # This themes Dolphin to dark mode.
  qt = {
    enable = true;
    platformTheme.name = "adwaita-dark";
    style.name = "adwaita-dark";
  };

  # Fixes the background colour issue with Dolphin
  home.file.".config/kdeglobals".source = ./kdeglobals;
}
