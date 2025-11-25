{
  lib,
  pkgs,
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
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [5900];
    };

    # 2. Authentication (PAM)
    # Required if secure mode is on (for username/password login)
    security.pam.services.wayvnc = mkIf cfg.secure {};

    # 3. Secrets Management
    # Only decrypt keys if we are in secure mode.
    sops = mkIf cfg.secure {
      defaultSopsFile = ../../../../secrets/secrets/wayvnc.yaml;
      defaultSopsFormat = "yaml";
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

      secrets = {
        "wayvnc_key" = {
          owner = "abl030"; # Adjust user if dynamic is needed
          mode = "0400";
        };
        "wayvnc_cert" = {
          owner = "abl030";
          mode = "0444";
        };
      };
    };
  };
}
