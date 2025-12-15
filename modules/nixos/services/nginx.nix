# modules/nixos/core/nginx.nix
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
      # FIXED: Added the extra 'secrets' directory to match your actual structure
      default = ../../../secrets/secrets/acme-cloudflare.env;
      description = "Path to sops file containing CLOUDFLARE_DNS_API_TOKEN.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Open Firewall
    networking.firewall.allowedTCPPorts = [80 443];

    # 2. Decrypt Cloudflare Credentials ONCE
    sops.secrets."acme/cloudflare" = {
      sopsFile = cfg.cloudflareSopsFile;
      format = "dotenv";
      owner = "acme";
      group = "nginx";
      # Restart nginx if credentials change
      restartUnits = ["nginx.service"];
    };

    # 3. Global ACME Configuration
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.acmeEmail;
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.secrets."acme/cloudflare".path;
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
