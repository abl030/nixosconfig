{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
in {
  # 1. Import storage (UDisks2) so Dolphin can mount drives
  imports = [
    ../system/storage.nix
  ];

  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland System Infrastructure";
  };

  config = mkIf cfg.enable {
    # Turn on our storage helpers for Dolphin automounting
    homelab.storage.enable = true;

    # --- ENVIRONMENT VARIABLES (System Authority) ---
    environment.sessionVariables = {
      # Use the KDE platform theme plugin (works outside Plasma)
      QT_QPA_PLATFORMTHEME = "KDE";

      # Critical for Dolphin "Open With" and MIME integration
      XDG_MENU_PREFIX = "plasma-";
    };

    # Hyprland compositor + Xwayland
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    # SDDM on Wayland
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    # Leave X server enabled (some apps and tools still want it)
    services.xserver.enable = true;

    # Portals for screensharing etc.
    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    # PAM entry so hyprlock can authenticate
    security.pam.services.hyprlock = {};
  };
}
