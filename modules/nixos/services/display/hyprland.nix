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
    # vnc option removed
  };

  config = mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    services.xserver.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    security.pam.services.hyprlock = {};
  };
}
