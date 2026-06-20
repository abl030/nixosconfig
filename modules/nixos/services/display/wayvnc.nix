{
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.vnc;
in {
  options.homelab.vnc = {
    enable = mkEnableOption "Enable WayVNC Server Support";
    secure = mkEnableOption "Enable Secure Mode (PAM Auth & TLS Encryption)";
    openFirewall = mkEnableOption "Open Firewall port 5900";
  };

  config = mkIf cfg.enable {
    # 1. Firewall
    # openFirewall opens 5900 on ALL interfaces (LAN included) — default off.
    # Regardless, expose 5900 on the tailnet: wayvnc is a tailnet remote-desktop
    # tool, and tailscale0 is no longer blanket-trusted (see
    # services/tailscale/default.nix), so it needs an explicit pinhole there —
    # previously it rode the interface trust.
    networking.firewall = {
      allowedTCPPorts = mkIf cfg.openFirewall [5900];
      interfaces.tailscale0.allowedTCPPorts = [5900];
    };

    # 2. Authentication (PAM)
    # Required if secure mode is on (for username/password login)
    security.pam.services.wayvnc = mkIf cfg.secure {};

    # 3. Secrets Management
    # Only decrypt keys if we are in secure mode.
    sops = mkIf cfg.secure {
      defaultSopsFile = config.homelab.secrets.sopsFile "wayvnc.yaml";
      defaultSopsFormat = "yaml";
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

      secrets = {
        "wayvnc_key" = {
          owner = "abl030"; # Adjust user if dynamic is needed
          mode = "0400";
        };
        "wayvnc_cert" = {
          owner = "abl030";
          # wayvnc runs as abl030 and reads this directly, so 0400 owner=abl030
          # is enough — was 0444 (world-readable, matching wayvnc_key's 0400). (#232)
          mode = "0400";
        };
      };
    };
  };
}
