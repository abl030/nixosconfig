{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
in {
  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland System Infrastructure";
  };

  config = mkIf cfg.enable {
    # 1. Enable the Hyprland Desktop Portal & Session Entry
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    # 2. SDDM needs to be enabled for login
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    # 3. Ensure the graphics subsystem is active
    services.xserver.enable = true;

    # 4. Portals (File pickers, screenshare)
    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    # We removed systemPackages here because we moved Ghostty/Wofi
    # to the Home Manager module, keeping things cleaner.
  };
}
