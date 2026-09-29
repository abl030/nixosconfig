# Cullen Emissions Ledger dashboard: serve the generated single-file HTML
# straight from the live cullen-carbon checkout, so regenerating
# dashboard/index.html is live on the next page load — no flake input, no
# rebuild. See docs/wiki/services/cullen-carbon-dashboard.md.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.cullenCarbon;
  # Where the dashboard directory appears inside nginx's mount namespace.
  servedDir = "/run/cullen-carbon-dashboard";
in {
  options.homelab.services.cullenCarbon = {
    enable = lib.mkEnableOption "Cullen Emissions Ledger dashboard";

    dashboardDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/abl030/cullen-carbon/dashboard";
      description = ''
        Live checkout directory holding the generated index.html. Bound
        read-only into nginx; only index.html is served.
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "carbon.ablz.au";
      description = "LAN HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8851;
      description = "Loopback HTTP port of the static nginx server behind localProxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    # nginx runs ProtectHome=true and the home directory is 0700. Bind just the
    # dashboard directory read-only into nginx's namespace instead of widening
    # either. Bind the directory, not the file: build.py and git replace
    # index.html with a new inode, which a file bind would never see. The "-"
    # prefix keeps nginx starting if the checkout is ever absent (the vhost
    # then 404s and the Kuma monitor alerts).
    systemd.services.nginx.serviceConfig.BindReadOnlyPaths = ["-${cfg.dashboardDir}:${servedDir}"];

    # Plain static loopback server; localProxy terminates TLS in front of it.
    services.nginx.virtualHosts."cullen-carbon-static" = {
      listen = [
        {
          addr = "127.0.0.1";
          inherit (cfg) port;
        }
      ];
      root = servedDir;
      locations = {
        # The dashboard directory also holds template.html and build.py;
        # expose only the generated page.
        "= /" = {
          tryFiles = "/index.html =404";
          extraConfig = ''
            add_header Cache-Control "no-cache" always;
          '';
        };
        "/".return = "404";
      };
    };

    # Ordinary LAN localProxy entry: unproxied Cloudflare DNS to doc1's RFC1918
    # address plus nginx TLS/ACME, the same shape as bd.ablz.au.
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Cullen carbon dashboard";
          url = "https://${cfg.fqdn}/";
        }
      ];
      # No process of its own: shared nginx serving one static file. A missing
      # or unreadable index.html is a non-200 on the Kuma monitor above.
      errorPatterns = [];
    };
  };
}
