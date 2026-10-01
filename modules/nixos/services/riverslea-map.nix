# Riverslea historical map: a static Leaflet site served live from the
# ~/riverslea-map checkout, with its aerial tiles read from a local tile cache.
# Same shape as family-map.nix. LAN-only: the Landgate imagery is a private
# research copy and must not be public. See docs/wiki/services/riverslea-map.md.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.riversleaMap;
  # Where the bound directories appear inside nginx's mount namespace.
  servedMaps = "/run/riverslea-map";
  servedTiles = "/run/riverslea-map-tiles";
in {
  options.homelab.services.riversleaMap = {
    enable = lib.mkEnableOption "Riverslea historical map";

    mapsDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/abl030/riverslea-map";
      description = ''
        Live checkout holding site/ and the data/ that site/data symlinks to.
        Bound read-only into nginx; only the site's own files are served.
      '';
    };

    tilesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/riverslea-map/tiles";
      description = ''
        Generated aerial tile cache on local disk (doc1's root is Proxmox NVMe).
        Regenerable, so not backed up. Local rather than NFS for the same
        small-file-create reason as family-map (docs/wiki/services/family-map.md).
        site/tiles symlinks here for local use.
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "riverslea.ablz.au";
      description = "LAN HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8853;
      description = "Loopback HTTP port of the static nginx server behind localProxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Local tile cache, written by the project's tools/build_tiles.py (runs as
    # abl030) and read by nginx.
    systemd.tmpfiles.rules = [
      "d /var/lib/riverslea-map 0755 abl030 users - -"
      "d ${cfg.tilesDir} 0755 abl030 users - -"
    ];

    # nginx runs ProtectHome=true and masks /mnt (nginx.nix, #257). Bind the
    # repo root (not site/: site/data is a relative symlink to ../data) and the
    # tile cache, read-only. Directory binds, so git and tile rebuilds
    # replacing files stay visible. "-" keeps nginx starting if either is
    # absent; the Kuma monitors then fail instead.
    systemd.services.nginx = {
      serviceConfig.BindReadOnlyPaths = [
        "-${cfg.mapsDir}:${servedMaps}"
        "-${cfg.tilesDir}:${servedTiles}"
      ];
    };

    # Plain static loopback server; localProxy terminates TLS in front of it.
    # The repo also holds tools, docs, caches and the README; expose only what
    # the page loads.
    services.nginx.virtualHosts."riverslea-map-static" = {
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
    # address plus nginx TLS/ACME, the same shape as family.ablz.au.
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Riverslea map";
          url = "https://${cfg.fqdn}/";
        }
        {
          name = "Riverslea map tiles";
          url = "https://${cfg.fqdn}/tiles/manifest.json";
        }
      ];
      # No process of its own: shared nginx serving static files.
      errorPatterns = [];
    };
  };
}
