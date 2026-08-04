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
      sopsFile = config.homelab.secrets.sopsFile "ntfy-server.env";
      format = "dotenv";
      mode = "0400";
    };

    # Upstream NixOS module. Authentication users, ACLs and tokens are
    # declaratively provisioned from a doc2-only SOPS secret.
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

    # ntfy's /json endpoint is an indefinite HTTP response. nginx's default
    # response buffering prevents Hermes from seeing events until the stream
    # closes, while the adapter intentionally reconnects if no keepalive data
    # arrives within 90 seconds. Forward each event immediately and keep the
    # upstream read open beyond that interval.
    services.nginx.virtualHosts.${cfg.fqdn}.locations."/".extraConfig = lib.mkAfter ''
      proxy_buffering off;
      proxy_read_timeout 3600s;
    '';

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
