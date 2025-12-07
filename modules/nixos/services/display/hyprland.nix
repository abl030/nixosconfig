{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
in {
  # 1. Import the storage definition here so Hyprland knows about it
  #    (Assuming you placed storage.nix in modules/nixos/services/system/storage.nix)
  imports = [
    ../system/storage.nix
  ];

  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland System Infrastructure";
  };

  config = mkIf cfg.enable {
    # 2. Trigger the "On" switch for storage automatically
    homelab.storage.enable = true;

    # --- Existing Hyprland Config ---
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
