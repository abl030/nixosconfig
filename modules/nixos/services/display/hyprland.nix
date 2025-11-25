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
    # Add the new toggle here
    vnc = mkEnableOption "Enable WayVNC Server (Port 5900)";
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

    # Open Firewall for VNC if enabled
    networking.firewall = mkIf cfg.vnc {
      allowedTCPPorts = [5900];
    };
  };
}
