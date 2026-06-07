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
      key = ""; # Output entire file content for ACME environmentFile
      owner = "acme";
      # Note: We removed restartUnits = ["nginx.service"] to prevent reload failures
    };

    # 3. Global ACME Configuration
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.acmeEmail;
        dnsProvider = "cloudflare";
        environmentFile = config.sops.secrets."acme/cloudflare".path;
        # Use public DNS for propagation checks (bypasses Tailscale's 100.100.100.100)
        dnsResolver = "1.1.1.1:53";
        extraLegoFlags = [
          "--dns.propagation-wait"
          "60s"
        ];
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
      commonHttpConfig = ''
        map $http_upgrade $connection_upgrade {
          default upgrade;
          "" close;
        }
      '';
    };

    users.users.nginx.extraGroups = ["acme"];

    # #257: secure-by-default — blank nginx's /mnt in the shared module so
    # every host (and every future VM) starts with nginx unable to see the
    # /mnt/* tree it almost never needs. nginx already runs
    # ProtectSystem=strict + PrivateMounts=yes, but those leave the
    # user-managed /mnt mounts visible; TemporaryFileSystem masks them.
    #
    # A reverse-proxy nginx (e.g. doc2) needs nothing bound back. Any host
    # that ALSO serves static files from /mnt opens that hole explicitly in
    # the module that defines the vhost, by adding the path to
    # `systemd.services.nginx.serviceConfig.BindPaths` + a matching
    # `RequiresMountsFor` (see podcast.nix for the pattern). This keeps the
    # /mnt hole co-located with the config that needs it, so it can't be
    # forgotten when a service moves hosts.
    # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
    systemd.services.nginx.serviceConfig.TemporaryFileSystem = "/mnt";
  };
}
