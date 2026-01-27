{
  lib,
  config,
  inputs,
  ...
}: let
  cfg = config.homelab.nginx;
in {
  imports = [inputs.sops-nix.nixosModules.sops];

  options.homelab.nginx = {
    enable = lib.mkEnableOption "Enable core Nginx & ACME infrastructure";

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "acme@ablz.au";
      description = "Contact email for Let's Encrypt.";
    };

    cloudflareSopsFile = lib.mkOption {
      type = lib.types.path;
      default = config.homelab.secrets.sopsFile "acme-cloudflare.env";
      description = "Path to sops file containing CLOUDFLARE_DNS_API_TOKEN.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Open Firewall
    networking.firewall.allowedTCPPorts = [80 443];

    # 2. Decrypt Cloudflare Credentials
    sops.secrets."acme/cloudflare" = {
      sopsFile = cfg.cloudflareSopsFile;
      format = "dotenv";
      key = ""; # Output entire file content for ACME credentialsFile
      owner = "acme";
      # Note: We removed restartUnits = ["nginx.service"] to prevent reload failures
    };

    # 3. Global ACME Configuration
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.acmeEmail;
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.secrets."acme/cloudflare".path;
        # Use public DNS for propagation checks (bypasses Tailscale's 100.100.100.100)
        dnsResolver = "1.1.1.1:53";
        # Skip local propagation checks; rely on ACME validation.
        dnsPropagationCheck = false;
        # Reload nginx when certs change
        reloadServices = ["nginx"];
        # validMinDays = 999;
      };
    };

    # 4. Nginx Base Configuration
    services.nginx = {
      enable = true;
      recommendedProxySettings = lib.mkDefault true;
      recommendedTlsSettings = lib.mkDefault true;
      recommendedGzipSettings = lib.mkDefault true;
      recommendedOptimisation = lib.mkDefault true;
    };

    users.users.nginx.extraGroups = ["acme"];
  };
}
