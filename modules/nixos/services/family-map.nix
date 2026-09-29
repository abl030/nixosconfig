# Barrett-Lennard family-history map: the static Leaflet site the family-history
# agent builds in ~/agents, served live from that checkout with its aerial tiles
# read from the tower NFS tile cache. LAN-only: the Landgate imagery is a private
# research copy and must not be public. See docs/wiki/services/family-map.md.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.familyMap;
  # Where the bound directories appear inside nginx's mount namespace.
  servedMaps = "/run/family-map";
  servedTiles = "/run/family-map-tiles";
in {
  options.homelab.services.familyMap = {
    enable = lib.mkEnableOption "Barrett-Lennard family-history map";

    mapsDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/abl030/agents/docs/wiki/family-history/maps";
      description = ''
        Live checkout directory holding site/ and the data/ its GeoJSON
        symlinks point into. Bound read-only into nginx; only the site's own
        files are served.
      '';
    };

    tilesDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Andy/Genealogy/Barrett-Lennard/Maps/tiles";
      description = "NFS tile cache that site/tiles symlinks to locally.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "family.ablz.au";
      description = "LAN HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8852;
      description = "Loopback HTTP port of the static nginx server behind localProxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    # nginx runs ProtectHome=true and masks /mnt (nginx.nix, #257). Bind only
    # the maps directory (not site/: site/data/* are relative symlinks into
    # ../../data) and the tile cache, read-only. Directory binds, so git and
    # tile rebuilds replacing files stay visible. "-" keeps nginx starting if
    # either is absent; the Kuma monitors then fail instead.
    systemd.services.nginx = {
      unitConfig.RequiresMountsFor = ["/mnt/data"];
      serviceConfig.BindReadOnlyPaths = [
        "-${cfg.mapsDir}:${servedMaps}"
        "-${cfg.tilesDir}:${servedTiles}"
      ];
    };

    # Plain static loopback server; localProxy terminates TLS in front of it.
    # maps/ also holds tools, indexes and the README; expose only what the
    # page loads.
    services.nginx.virtualHosts."family-map-static" = {
      listen = [
        {
          addr = "127.0.0.1";
          inherit (cfg) port;
        }
      ];
      root = "${servedMaps}/site";
      locations = {
        "~ ^/(index\\.html|app\\.js|config\\.js|style\\.css)?$" = {
          tryFiles = "$uri /index.html =404";
          extraConfig = ''
            add_header Cache-Control "no-cache" always;
          '';
        };
        "~ ^/data/[A-Za-z0-9._-]+\\.(geojson|md)$".extraConfig = ''
          add_header Cache-Control "no-cache" always;
        '';
        "~ ^/vendor/leaflet/[A-Za-z0-9._/-]+\\.(js|css|png)$" = {};
        "= /tiles/manifest.json" = {
          alias = "${servedTiles}/manifest.json";
          extraConfig = ''
            add_header Cache-Control "no-cache" always;
          '';
        };
        # Tiles are rebuilt occasionally; a day's cache keeps panning cheap.
        "~ ^/tiles/(?<tile>[0-9]+/[0-9]+/[0-9]+/[0-9]+\\.(?:png|jpg|webp))$" = {
          alias = "${servedTiles}/$tile";
          extraConfig = ''
            add_header Cache-Control "public, max-age=86400" always;
          '';
        };
        "/".return = "404";
      };
    };

    # Ordinary LAN localProxy entry: unproxied Cloudflare DNS to doc1's RFC1918
    # address plus nginx TLS/ACME, the same shape as carbon.ablz.au.
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Family map";
          url = "https://${cfg.fqdn}/";
        }
        {
          name = "Family map tiles";
          url = "https://${cfg.fqdn}/tiles/manifest.json";
        }
      ];
      # No process of its own: shared nginx serving static files.
      errorPatterns = [];
    };
  };
}
