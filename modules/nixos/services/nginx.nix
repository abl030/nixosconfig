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
      # Adjust path if your file structure differs, but ../../../ goes to repo root from modules/nixos/services/
      default = ../../../secrets/secrets/acme-cloudflare.env;
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
        # Reload nginx when certs change
        reloadServices = ["nginx"];
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
