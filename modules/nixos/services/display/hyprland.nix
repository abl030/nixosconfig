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
    vnc = mkEnableOption "Enable WayVNC Server (Authenticated & Encrypted)";
  };

  config = mkIf cfg.enable {
    # 1. Basic Desktop Infrastructure
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

    # PAM service so hyprlock can use pam:module = "hyprlock"
    security.pam.services.hyprlock = {};

    # 2. VNC Infrastructure (Only if VNC is enabled)
    security.pam.services.wayvnc = mkIf cfg.vnc {};

    # We rely on Tailscale trusted interfaces, so we generally don't open
    # port 5900 to the public LAN. Uncomment if you need LAN access without Tailscale.
    # networking.firewall = mkIf cfg.vnc {
    #   allowedTCPPorts = [ 5900 ];
    # };

    # 3. Secrets Management for VNC
    # This assumes 'sops-nix' module is imported in your main configuration.nix
    sops = mkIf cfg.vnc {
      # Path is relative to THIS file:
      # modules/nixos/services/display/ -> ../../../../ -> secrets/secrets/wayvnc.yaml
      defaultSopsFile = ../../../../secrets/secrets/wayvnc.yaml;
      defaultSopsFormat = "yaml";

      # age.keyFile = "/var/lib/sops-nix/key.txt";
      # Extract host key automatically
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

      secrets = {
        "wayvnc_key" = {
          owner = "abl030"; # Hardcoded to your user
          mode = "0400"; # Read-only by owner (safer than 0600)
        };
        "wayvnc_cert" = {
          owner = "abl030";
          mode = "0444"; # Readable by anyone (it's a public cert)
        };
      };
    };
  };
}
