{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.webdav;
in {
  options.homelab.services.webdav = {
    enable = lib.mkEnableOption "WebDAV file server";
  };

  config = lib.mkIf cfg.enable {
    services.webdav = {
      enable = true;
      environmentFile = config.sops.secrets."webdav/env".path;
      settings = {
        # Localhost-only: reached via the localProxy vhost (webdav.ablz.au) and
        # Zotero syncs to that FQDN. 0.0.0.0 would expose it unauthenticated to
        # the whole tailnet (tailscale0 is a trusted firewall interface).
        address = "127.0.0.1";
        port = 9090;
        directory = "/mnt/data/Life/Andy/Education/Zotero Library";
        permissions = "CRUD";
        users = [
          {
            username = "{env}WEBDAV_USERNAME";
            password = "{env}WEBDAV_PASSWORD";
          }
        ];
      };
    };

    # WebDAV needs NFS mount for Zotero library — and ONLY that one dir.
    # #257: was unhardened with the full /mnt/* tree RW-visible. The server
    # serves exactly `directory` above, so blank /mnt and bind back only the
    # Zotero Library subdir (rw — permissions=CRUD). The source path has a
    # literal space, escaped `\ ` per systemd.exec(5); bound to the same
    # space-bearing path so the `directory` setting needs no change.
    # ProtectSystem=strict on top (simple Go file server, writes only there).
    # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
    systemd.services.webdav = {
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
      unitConfig.RequiresMountsFor = ["/mnt/data/Life/Andy/Education/Zotero Library"];
      serviceConfig = {
        ProtectSystem = "strict";
        TemporaryFileSystem = "/mnt";
        BindPaths = [''/mnt/data/Life/Andy/Education/Zotero\ Library''];
      };
    };

    sops.secrets."webdav/env" = {
      sopsFile = config.homelab.secrets.sopsFile "webdav.env";
      format = "dotenv";
      owner = "webdav";
      mode = "0400";
    };

    homelab = {
      nfsWatchdog.webdav.path = "/mnt/data";

      localProxy.hosts = [
        {
          host = "webdav.ablz.au";
          port = 9090;
        }
      ];

      monitoring.monitors = [
        {
          name = "WebDav";
          url = "https://webdav.ablz.au/";
          acceptedStatusCodes = ["200-299" "300-399" "401"];
        }
      ];

      # See #253 audit. Simple file server; NFS-backed outages already
      # covered by the nfsWatchdog above + Kuma HTTP monitor. NAMESPACE/bind
      # start-failures page ONCE via the fleet-wide "Service failed to start
      # (sandbox/namespace)" alert in alerting.nix — no per-service entry
      # (storm de-collide 2026-06-26).
      monitoring.errorPatterns = []; # ^ namespace → fleet alert; real outages → Kuma
    };
  };
}
