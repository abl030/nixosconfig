# Family-history source archive viewer: the static site `fh build` generates
# from the catalogue in ~/family-history, plus the archived originals served
# read-only from the NAS. LAN-only: the archive holds certificates and papers
# of living people. One copy of each original exists (on the NAS); the site
# directory only holds HTML and small derivatives, so it is regenerable and
# not backed up. See docs/wiki/services/family-archive.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.familyArchive;
  servedSite = "/run/family-archive-site";
  servedOriginals = "/run/family-archive-originals";
  servedTiles = "/run/family-archive-tiles";
  servedBasemap = "/run/family-archive-basemap";
  servedPublic = "/run/family-archive-public";

  # One step from doc1 after each export: snapshot the served preview with
  # hard links, leak-check exactly that snapshot, push it one way into the
  # public guest (doc2's familypub microVM) and make it live. The guest's
  # forced command allows only an rsync into staging, `activate` and
  # `status`. See docs/wiki/services/family-public-site.md.
  pub = cfg.publicSite;
  publishScript = pkgs.writeShellApplication {
    name = "family-public-publish";
    runtimeInputs = with pkgs; [rsync openssh coreutils util-linux curl];
    text = ''
      site=''${1:-${cfg.publicPreview.siteDir}}
      ssh_cmd=(ssh -i ${config.sops.secrets."family-public/publish-key".path}
        -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes)
      if [[ "$site" == status ]]; then
        exec "''${ssh_cmd[@]}" publish@${pub.host} status
      fi
      [[ -f "$site/index.html" ]] || {
        echo "no site at $site" >&2
        exit 1
      }

      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/family-public-publish.lock"
      flock -n 9 || {
        echo "another publish is running" >&2
        exit 1
      }
      mkdir -p "$HOME/.cache/fh"
      snap=$(mktemp -d "$HOME/.cache/fh/publish.XXXXXX")
      trap 'rm -rf "$snap"' EXIT
      # Same filesystem, so this is cheap, and a concurrent `fh export
      # --serve` can't change what is checked after the check.
      cp -al "$site" "$snap/site"

      echo "leak check: $snap/site"
      ${pub.fhCommand} export --check "$snap/site"

      echo "upload to ${pub.host}"
      rsync -a --delete --stats -e "''${ssh_cmd[*]}" "$snap/site/" publish@${pub.host}:
      "''${ssh_cmd[@]}" publish@${pub.host} activate

      # Cloudflare holds pages a day at the edge and the asset URLs carry no
      # version, so a new release purges the zone. The token can only purge.
      echo "purge Cloudflare cache"
      curl -fsS -X POST -H 'Content-Type: application/json' \
        -H @<(printf 'Authorization: Bearer %s\n' "$(cat ${config.sops.secrets."family-public/cf-purge".path})") \
        --data '{"purge_everything":true}' \
        "https://api.cloudflare.com/client/v4/zones/${pub.cloudflareZoneId}/purge_cache" >/dev/null
      echo "purged"
    '';
  };
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

    # The public site (`fh export --public`, family-history issue #137): the
    # catalogue scrubbed of living people and of what can't be published,
    # downscaled images inside it. Previewed here on the LAN before it is
    # hosted publicly from an isolated VM; nothing else is mounted.
    publicPreview = {
      enable = lib.mkEnableOption "LAN preview of the public family-history site";

      siteDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/family-archive/public-site";
        description = "The cleared site `fh export --serve` writes (abl030-writable, regenerable).";
      };

      fqdn = lib.mkOption {
        type = lib.types.str;
        default = "public-preview.ablz.au";
        description = "LAN HTTPS hostname served by homelab.localProxy.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8855;
        description = "Loopback HTTP port of the preview's static nginx server.";
      };
    };

    # Publishing to family.barrett-lennard.com (nixosconfig #250); the guest
    # is defined in hosts/doc2/family-public-microvm.nix.
    publicSite = {
      enable = lib.mkEnableOption "the `family-public-publish` command for the public site";

      host = lib.mkOption {
        type = lib.types.str;
        default = "192.168.22.2";
        description = "The public guest on FAMILY_DMZ; pfSense admits SSH to it from doc1 only.";
      };

      hostKey = lib.mkOption {
        type = lib.types.str;
        description = "The guest's SSH host key (kept on its site volume), pinned here.";
      };

      fhCommand = lib.mkOption {
        type = lib.types.str;
        default = "/home/abl030/family-history/bin/fh";
        description = "The family-history CLI whose `export --check` gates every publish.";
      };

      cloudflareZoneId = lib.mkOption {
        type = lib.types.str;
        default = "3312c076271b9036adcbd0ec5df55dda";
        description = "The barrett-lennard.com zone, purged after each publish.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pub.enable -> cfg.publicPreview.enable;
        message = "familyArchive.publicSite publishes the public preview; enable publicPreview";
      }
    ];

    sops.secrets."family-public/publish-key" = lib.mkIf pub.enable {
      sopsFile = config.homelab.secrets.sopsFile "family-public-publish-key";
      format = "binary";
      owner = "abl030";
      mode = "0400";
    };
    # Purge-only Cloudflare token for barrett-lennard.com (no other scope).
    sops.secrets."family-public/cf-purge" = lib.mkIf pub.enable {
      sopsFile = config.homelab.secrets.sopsFile "family-public-cf-purge";
      format = "binary";
      owner = "abl030";
      mode = "0400";
    };
    programs.ssh.knownHosts.family-public = lib.mkIf pub.enable {
      hostNames = [pub.host];
      publicKey = pub.hostKey;
    };
    environment.systemPackages = lib.optional pub.enable publishScript;

    systemd.tmpfiles.rules =
      [
        "d /var/lib/family-archive 0755 abl030 users - -"
        "d ${cfg.siteDir} 0755 abl030 users - -"
      ]
      ++ lib.optional cfg.publicPreview.enable "d ${cfg.publicPreview.siteDir} 0755 abl030 users - -";

    # Read-only directory binds; "-" keeps nginx starting if the NAS is down
    # (the Kuma monitor on an original then fails instead).
    systemd.services.nginx.serviceConfig.BindReadOnlyPaths =
      [
        "-${cfg.siteDir}:${servedSite}"
        "-${cfg.originalsDir}:${servedOriginals}"
        "-${cfg.tilesDir}:${servedTiles}"
        "-${cfg.basemapDir}:${servedBasemap}"
      ]
      ++ lib.optional cfg.publicPreview.enable "-${cfg.publicPreview.siteDir}:${servedPublic}";

    # The public preview: only the cleared site, nothing from the NAS. The
    # same headers the public host will send, so the preview behaves like it.
    services.nginx.virtualHosts."family-public-preview" = lib.mkIf cfg.publicPreview.enable {
      listen = [
        {
          addr = "127.0.0.1";
          inherit (cfg.publicPreview) port;
        }
      ];
      root = servedPublic;
      locations."/" = {
        tryFiles = "$uri $uri/index.html =404";
        extraConfig = ''
          add_header Cache-Control "no-cache" always;
          add_header X-Content-Type-Options nosniff always;
          add_header Referrer-Policy same-origin always;
          add_header X-Robots-Tag "noindex" always;
        '';
      };
    };
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

    homelab.localProxy.hosts =
      [
        {
          host = cfg.fqdn;
          inherit (cfg) port;
        }
      ]
      ++ lib.optional cfg.publicPreview.enable {
        host = cfg.publicPreview.fqdn;
        inherit (cfg.publicPreview) port;
      };

    homelab.monitoring = {
      monitors =
        [
          {
            name = "Family sources";
            url = "https://${cfg.fqdn}/";
          }
          {
            name = "Family sources map tiles";
            url = "https://${cfg.fqdn}/tiles/manifest.json";
          }
        ]
        ++ lib.optional cfg.publicPreview.enable {
          name = "Family public preview";
          url = "https://${cfg.publicPreview.fqdn}/";
        }
        # The public site end to end: Cloudflare, the tunnel, the guest.
        ++ lib.optional pub.enable {
          name = "Family public site";
          url = "https://family.barrett-lennard.com/api/index.json";
        };
      errorPatterns = [];
    };
  };
}
