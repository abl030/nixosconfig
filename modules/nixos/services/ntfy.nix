{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.ntfy;
in {
  options.homelab.services.ntfy = {
    enable = lib.mkEnableOption "private ntfy push and Hermes chat server";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "ntfy.ablz.au";
      description = "HTTPS hostname served by the host-local reverse proxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8092;
      description = "Loopback HTTP port for ntfy-sh.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."ntfy/env" = {
      sopsFile = config.homelab.secrets.sopsFile "ntfy.env";
      format = "dotenv";
      mode = "0400";
    };

    # Upstream NixOS module. Authentication users, ACLs and tokens are
    # declaratively provisioned from the shared doc1/doc2 SOPS secret.
    services.ntfy-sh = {
      enable = true;
      environmentFile = config.sops.secrets."ntfy/env".path;
      settings = {
        base-url = "https://${cfg.fqdn}";
        listen-http = "127.0.0.1:${toString cfg.port}";
        cache-file = "/var/lib/ntfy-sh/cache.db";
        auth-file = "/var/lib/ntfy-sh/user.db";
        auth-default-access = "deny-all";
        behind-proxy = true;
        enable-login = true;
        enable-signup = false;
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          inherit (cfg) port;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "ntfy";
          url = "https://${cfg.fqdn}/v1/health";
        }
      ];

      # The health endpoint is the useful availability signal. Transient
      # subscriber disconnects are expected and should not page.
      monitoring.errorPatterns = [];
    };
  };
}
