# Family-history source archive viewer: the static site `fh build` generates
# from the catalogue in ~/family-history, plus the archived originals served
# read-only from the NAS. LAN-only: the archive holds certificates and papers
# of living people. One copy of each original exists (on the NAS); the site
# directory only holds HTML and small derivatives, so it is regenerable and
# not backed up. See docs/wiki/services/family-archive.md.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.familyArchive;
  servedSite = "/run/family-archive-site";
  servedOriginals = "/run/family-archive-originals";
  servedTiles = "/run/family-archive-tiles";
  servedBasemap = "/run/family-archive-basemap";
in {
  options.homelab.services.familyArchive = {
    enable = lib.mkEnableOption "family-history source archive viewer";

    siteDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/family-archive/site";
      description = "Output of `fh build` (abl030-writable, local disk, regenerable).";
    };

    originalsDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Andy/Genealogy/Archive";
      description = "The NAS archive: one folder of originals per source ID. Read-only to nginx.";
    };

    tilesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/family-map/tiles";
      description = ''
        Aerial photograph tiles for the site's map, on local disk (built by the
        family-history repo's maps/tools/build_tiles.py from local copies of the
        masters; regenerable, not backed up). Served at /tiles/. Landgate years
        are a private research copy: this host stays LAN-only.
      '';
    };

    basemapDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/family-archive/basemap";
      description = ''
        The map's self-hosted street map: OpenStreetMap vector tiles in two
        PMTiles files (world, detail) cut by `fh basemap` from a Protomaps
        build, on local disk; regenerable, not backed up. Served at /basemap/
        so the map never streams from OpenStreetMap's servers.
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "sources.ablz.au";
      description = "LAN HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8854;
      description = "Loopback HTTP port of the static nginx server behind localProxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/family-archive 0755 abl030 users - -"
      "d ${cfg.siteDir} 0755 abl030 users - -"
    ];

    # Read-only directory binds; "-" keeps nginx starting if the NAS is down
    # (the Kuma monitor on an original then fails instead).
    systemd.services.nginx.serviceConfig.BindReadOnlyPaths = [
      "-${cfg.siteDir}:${servedSite}"
      "-${cfg.originalsDir}:${servedOriginals}"
      "-${cfg.tilesDir}:${servedTiles}"
      "-${cfg.basemapDir}:${servedBasemap}"
    ];
    # Ordering only, never Requires: on a normal boot let the NFS mount land
    # before nginx builds its namespace so the originals bind isn't skipped;
    # if tower is down the mount job fails and nginx starts anyway.
    systemd.services.nginx.after = lib.optional (lib.hasPrefix "/mnt/data/" cfg.originalsDir) "mnt-data.mount";

    services.nginx.virtualHosts."family-archive-static" = {
      listen = [
        {
          addr = "127.0.0.1";
          inherit (cfg) port;
        }
      ];
      root = servedSite;
      # Headers are set per location: a nested add_header drops the parent's.
      locations = {
        "/" = {
          tryFiles = "$uri $uri/index.html =404";
          extraConfig = ''
            add_header Cache-Control "no-cache" always;
            add_header X-Content-Type-Options nosniff always;
            add_header Referrer-Policy same-origin always;
          '';
        };
        # Revalidated on every load (a 304 on the LAN): the asset URLs carry
        # no version, and an hour's cache kept a fixed map.js broken.
        "/assets/".extraConfig = ''
          add_header Cache-Control "no-cache" always;
          add_header X-Content-Type-Options nosniff always;
          add_header Referrer-Policy same-origin always;
        '';
        # Originals, straight from the NAS. Source IDs are S- plus six
        # Crockford base32 characters; nothing else under the archive is
        # reachable. Quoted: nginx (and the config formatter) split an
        # unquoted regex at its {6}.
        "~ \"^/o/(?<sid>S-[0-9A-HJKMNP-TV-Z]{6})/(?<file>[^/]+)$\"" = {
          alias = "${servedOriginals}/$sid/$file";
          extraConfig = ''
            add_header Cache-Control "public, max-age=86400" always;
            add_header X-Content-Type-Options nosniff always;
            add_header Referrer-Policy same-origin always;
            # Saved web pages are third-party HTML: render them with no
            # scripts, forms or same-origin access.
            add_header Content-Security-Policy "sandbox; default-src 'none'; img-src data: 'self'; style-src 'unsafe-inline' data:; font-src data:; media-src 'self'" always;
          '';
        };
        "/o/".return = "404";
        # The map's aerial tiles, from local disk: the manifest and
        # <year>/<z>/<x>/<y> images only (no listings, no build scratch).
        "= /tiles/manifest.json" = {
          alias = "${servedTiles}/manifest.json";
          extraConfig = ''
            add_header Cache-Control "no-cache" always;
            add_header X-Content-Type-Options nosniff always;
          '';
        };
        # Tiles are rebuilt occasionally; a day's cache keeps panning cheap.
        "~ ^/tiles/(?<tile>[0-9]+/[0-9]+/[0-9]+/[0-9]+\\.(?:png|jpg|webp))$" = {
          alias = "${servedTiles}/$tile";
          extraConfig = ''
            add_header Cache-Control "public, max-age=86400" always;
            add_header X-Content-Type-Options nosniff always;
          '';
        };
        "/tiles/".return = "404";
        # The street map: two PMTiles archives the browser reads by byte range
        # (nginx answers Range on static files). Re-cut about yearly.
        "~ ^/basemap/(?<pmtiles>(?:world|detail)\\.pmtiles)$" = {
          alias = "${servedBasemap}/$pmtiles";
          extraConfig = ''
            add_header Cache-Control "public, max-age=86400" always;
            add_header X-Content-Type-Options nosniff always;
          '';
        };
        "/basemap/".return = "404";
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Family sources";
          url = "https://${cfg.fqdn}/";
        }
        {
          name = "Family sources map tiles";
          url = "https://${cfg.fqdn}/tiles/manifest.json";
        }
      ];
      errorPatterns = [];
    };
  };
}
