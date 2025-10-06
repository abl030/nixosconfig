# modules/nixos/nginx-nix-mirror.nix
{
  lib,
  config,
  inputs,
  ...
}: let
  cfg = config.homelab.services.nginxNixMirror or {};
  secretName = cfg.cloudflare.secretName;
in {
  # Pull in sops-nix so this module is self-contained.
  imports = [inputs.sops-nix.nixosModules.sops];

  options.homelab.services.nginxNixMirror = {
    enable = lib.mkEnableOption "Transparent pull-through mirror of cache.nixos.org via nginx";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Public hostname (e.g., nix-mirror.example.org).";
    };

    cacheRoot = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/nginx-nix-mirror";
      description = "Root directory for cached artifacts and temp areas.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Contact email for ACME; if null, uses global defaults.";
    };

    # SOPS/age config kept here so the module owns decryption.
    sopsAgeKeyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = ["/etc/ssh/ssh_host_ed25519_key"];
      description = "age private key paths for decryption (default: host SSH key).";
    };

    cloudflare = {
      sopsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the encrypted dotenv file containing Cloudflare LEGO vars,
          e.g. "CLOUDFLARE_DNS_API_TOKEN=...".
          This file stays encrypted in-git; sops-nix decrypts it at runtime.
        '';
        example = ./secrets/acme-cloudflare.env;
      };

      secretName = lib.mkOption {
        type = lib.types.str;
        default = "acme/cloudflare.env";
        description = "sops-nix secret name under config.sops.secrets.";
      };

      dnsPropagationCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable DNS propagation checks in ACME.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Decrypt using the provided age key paths (default: host SSH key).
    sops.age.sshKeyPaths = cfg.sopsAgeKeyPaths;

    # Materialize the Cloudflare dotenv at runtime; never enters /nix/store.
    sops.secrets.${secretName} = {
      sopsFile = cfg.cloudflare.sopsFile;
      owner = "acme";
      group = "acme";
      mode = "0400";
      format = "dotenv";
      restartUnits = [
        "nginx.service"
        "acme-${cfg.hostName}.service"
      ];
    };

    # ACME DNS-01 (Cloudflare) and cert for the mirror host.
    security.acme = {
      acceptTerms = true; # this module manages a public hostname; consent is explicit here
      defaults = lib.mkIf (cfg.acmeEmail != null) {email = cfg.acmeEmail;};
      certs."${cfg.hostName}" = {
        domain = cfg.hostName;
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.secrets.${secretName}.path; # runtime decrypted dotenv
        dnsPropagationCheck = cfg.cloudflare.dnsPropagationCheck;
      };
    };

    # Allow nginx to read ACME certs.
    users.users.nginx.extraGroups = ["acme"];

    # Nginx vhost: cache only the Nix endpoints with proxy_store.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts."${cfg.hostName}" = {
        useACMEHost = cfg.hostName;
        forceSSL = true;

        # /nix-cache-info (immutable metadata)
        locations."~ ^/nix-cache-info$".extraConfig = ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
          proxy_temp_path    ${cfg.cacheRoot}/nix-cache-info/temp;
          root               ${cfg.cacheRoot}/nix-cache-info/store;

          proxy_set_header   Host "cache.nixos.org";
          proxy_pass         https://cache.nixos.org;
        '';

        # /nar/... (immutable NARs)
        locations."~ ^/nar/.+$".extraConfig = ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
          proxy_temp_path    ${cfg.cacheRoot}/nar/temp;
          root               ${cfg.cacheRoot}/nar/store;

          proxy_set_header   Host "cache.nixos.org";
          proxy_pass         https://cache.nixos.org;
        '';
      };
    };

    # Create writable cache dirs; allow nginx unit to write into them.
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheRoot}                         0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info         0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info/store   0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info/temp    0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar                    0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar/store              0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar/temp               0750 nginx nginx -"
    ];
    systemd.services.nginx.serviceConfig.ReadWritePaths = [
      cfg.cacheRoot
      "${cfg.cacheRoot}/nix-cache-info/temp"
      "${cfg.cacheRoot}/nar/temp"
    ];

    networking.firewall.allowedTCPPorts = [80 443];
  };
}
