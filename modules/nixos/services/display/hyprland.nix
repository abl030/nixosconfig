{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
in {
  # Import the official NixOS module from the flake
  imports = [inputs.hyprland.nixosModules.default];

  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland System Infrastructure (Bleeding Edge)";
    # vnc option removed
  };

  config = mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      # Explicitly use the package from the flake input
      package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      # Make sure the portal matches the hyprland version
      portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    };

    # --- PIN MESA ---
    # To avoid "Version mismatch" errors, we use the Mesa version that Hyprland was built against.
    # We access the nixpkgs instance inside the Hyprland flake to get these drivers.
    hardware.graphics = {
      package = inputs.hyprland.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.mesa;
      package32 = inputs.hyprland.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.pkgsi686Linux.mesa;
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
