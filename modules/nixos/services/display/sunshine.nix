{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.sunshine;
in {
  options.homelab.sunshine = {
    enable = mkEnableOption "Enable Sunshine Game Stream Server";
  };

  config = mkIf cfg.enable {
    # 1. Enable Sunshine Service
    services.sunshine = {
      enable = true;
      autoStart = true;
      capSysAdmin = true; # Required for Wayland/KMS capture
      openFirewall = false; # We manually open ports on Tailscale only
      settings = {
        capture = "wlr";
      };
    };

    # 2. Hardware Encoding Drivers (Intel specific for 'epi')
    # Ensure oneVPL and Media Drivers are present for VAAPI encoding
    hardware.graphics.extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];

    # # 3. Firewall - Allow Sunshine only on Tailscale interface (tailscale0)
    # networking.firewall.interfaces."tailscale0" = {
    #   allowedTCPPorts = [47984 47989 47990 48010];
    #   allowedUDPPorts = [47998 47999 48000 48002 48010];
    # };

    # 4. Avahi/DNS-SD (Optional: helps Moonlight find the host)
    services.avahi.publish.userServices = true;
  };
}
