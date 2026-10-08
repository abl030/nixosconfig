# Barrett-Lennard family-history map: the static Leaflet site the family-history
# agent builds in ~/family-history, served live from that checkout with its aerial tiles
# read from a local tile cache (built from masters on the tower NFS share). LAN-only: the Landgate imagery is a private
# research copy and must not be public. Shared to Dad's tailnet as
# familymap.ablz.au via a doc2 tailscaleShare proxying this vhost (doc2 config).
# See docs/wiki/services/family-map.md.
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
      default = "/home/abl030/family-history/maps";
      description = ''
        Live checkout directory holding site/ and the data/ its GeoJSON
        symlinks point into. Bound read-only into nginx; only the site's own
        files are served.
      '';
    };

    tilesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/family-map/tiles";
      description = ''
        Generated aerial tile cache on local disk (doc1's root is Proxmox NVMe).
        The masters it is built from stay on the NAS; the tiles are regenerable,
        so this is not backed up. Local because the build writes ~80k small files
        a year and NFS manages ~6 creates/s against ~7,000 locally (2026-10-01).
        The build's scratch (.build-tmp) lives inside it so each year's swap is an
        atomic rename on one filesystem. site/tiles symlinks here for local use.
      '';
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
    # Local tile cache, written by the family-history agent's build_tiles.py
    # (runs as abl030) and read by nginx.
    systemd.tmpfiles.rules = [
      "d /var/lib/family-map 0755 abl030 users - -"
      "d ${cfg.tilesDir} 0755 abl030 users - -"
    ];

    # nginx runs ProtectHome=true and masks /mnt (nginx.nix, #257). Bind only
    # the maps directory (not site/: site/data/* are relative symlinks into
    # ../../data) and the tile cache, read-only. Directory binds, so git and
    # tile rebuilds replacing files stay visible. "-" keeps nginx starting if
    # either is absent; the Kuma monitors then fail instead. Nothing here needs
    # /mnt/data any more.
    systemd.services.nginx = {
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
