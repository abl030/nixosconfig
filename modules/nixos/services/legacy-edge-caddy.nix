{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.legacyEdgeCaddy;

  certName = "ablz.au";
  certDir = config.security.acme.certs.${certName}.directory;

  tlsLine = "tls ${certDir}/cert.pem ${certDir}/key.pem";

  transportBlock = entry:
    lib.optionalString entry.insecureSkipVerify ''
      {
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

  mkProxyConfig = entry: ''
    ${lib.optionalString (entry.encode != []) "encode ${lib.concatStringsSep " " entry.encode}"}
    ${lib.optionalString (entry.redirectRootTo != null) ''
      @rootPath path /
      redir @rootPath ${entry.redirectRootTo}
    ''}
    reverse_proxy ${entry.upstream} ${transportBlock entry}
  '';

  entryType = lib.types.submodule {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "FQDN served by the legacy edge Caddy instance.";
      };
      upstream = lib.mkOption {
        type = lib.types.str;
        description = "Caddy reverse_proxy upstream dial target, including scheme when needed.";
      };
      insecureSkipVerify = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable TLS verification for HTTPS upstreams with self-signed certs.";
      };
      encode = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Optional Caddy encode algorithms for this vhost.";
      };
      redirectRootTo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional redirect target for exact root path before proxying.";
      };
    };
  };

  defaultEntries = [
    {
      host = "apollo.ablz.au";
      upstream = "https://192.168.1.111:47990";
      insecureSkipVerify = true;
    }
    {
      host = "backup.ablz.au";
      upstream = "192.168.1.2:8200";
    }
    {
      host = "brother.ablz.au";
      upstream = "https://192.168.1.21";
      insecureSkipVerify = true;
    }
    {
      host = "calibre.ablz.au";
      upstream = "http://192.168.1.2:8084";
    }
    {
      host = "chat.ablz.au";
      upstream = "192.168.1.12:8080";
    }
    {
      host = "cockpit.ablz.au";
      upstream = "https://192.168.1.5:9090";
      insecureSkipVerify = true;
    }
    {
      host = "deluge.ablz.au";
      upstream = "192.168.1.4:8112";
    }
    {
      host = "dozzle.ablz.au";
      upstream = "http://192.168.1.29:8082";
    }
    {
      host = "epi.ablz.au";
      upstream = "https://192.168.1.5:8006";
      insecureSkipVerify = true;
    }
    {
      host = "home.ablz.au";
      upstream = "192.168.1.20:8123";
    }
    {
      host = "lidarr.ablz.au";
      upstream = "192.168.1.4:8686";
    }
    {
      host = "meg.ablz.au";
      upstream = "192.168.1.2:5055";
    }
    {
      host = "mumnas.ablz.au";
      upstream = "100.100.237.21:5000";
    }
    {
      host = "mumrouter.ablz.au";
      upstream = "192.168.4.1:80";
    }
    {
      host = "nzbget.ablz.au";
      upstream = "192.168.1.17:6789";
    }
    {
      host = "nzbhydra.ablz.au";
      upstream = "192.168.1.18:5076";
    }
    {
      host = "paperlessai.ablz.au";
      upstream = "192.168.1.29:3001";
    }
    {
      host = "pihole.ablz.au";
      upstream = "192.168.1.9:80";
      encode = ["zstd" "gzip"];
      redirectRootTo = "/admin{uri}";
    }
    {
      host = "plex.ablz.au";
      upstream = "192.168.30.2:32400";
    }
    {
      host = "prom.ablz.au";
      upstream = "https://192.168.1.12:8006";
      insecureSkipVerify = true;
    }
    {
      host = "router.ablz.au";
      upstream = "https://192.168.1.1";
      insecureSkipVerify = true;
    }
    {
      host = "slb.ablz.au";
      upstream = "192.168.1.23:80";
    }
    {
      host = "slsk.ablz.au";
      upstream = "192.168.11.3:6080";
    }
    {
      host = "sync.ablz.au";
      upstream = "http://192.168.1.2:8384";
    }
    {
      host = "tag.ablz.au";
      upstream = "192.168.1.2:5800";
    }
    {
      host = "tdarr.ablz.au";
      upstream = "192.168.1.2:8265";
    }
    {
      host = "tower.ablz.au";
      upstream = "192.168.1.2:80";
    }
    {
      host = "vpnpihole.ablz.au";
      upstream = "192.168.1.4:80";
      encode = ["zstd" "gzip"];
      redirectRootTo = "/admin{uri}";
    }
    {
      host = "warehousesolar.ablz.au";
      upstream = "https://192.168.100.133:443";
      insecureSkipVerify = true;
    }
    {
      host = "winerysolar.ablz.au";
      upstream = "https://192.168.100.139:443";
      insecureSkipVerify = true;
    }
    {
      host = "youtube.ablz.au";
      upstream = "192.168.1.6:3000";
    }
    {
      host = "zigbee.ablz.au";
      upstream = "192.168.1.22:8080";
    }
  ];
in {
  options.homelab.services.legacyEdgeCaddy = {
    enable = lib.mkEnableOption "legacy edge Caddy reverse proxy for non-Nix-managed homelab vhosts";

    entries = lib.mkOption {
      type = lib.types.listOf entryType;
      default = defaultEntries;
      description = ''
        Legacy vhosts that remain on the edge Caddy box. Vhosts that already have
        first-class homelab.localProxy service modules should not be listed here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Shared Cloudflare DNS-01 token. This mirrors homelab.nginx without enabling
    # nginx, because this edge host binds 80/443 with Caddy.
    sops.secrets."acme/cloudflare" = {
      sopsFile = config.homelab.secrets.sopsFile "acme-cloudflare.env";
      format = "dotenv";
      key = "";
      owner = "acme";
    };

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "acme@ablz.au";
        dnsProvider = "cloudflare";
        environmentFile = config.sops.secrets."acme/cloudflare".path;
        dnsResolver = "1.1.1.1:53";
        extraLegoFlags = [
          "--dns.propagation-wait"
          "60s"
        ];
      };
      certs.${certName} = {
        domain = certName;
        extraDomainNames = ["*.ablz.au"];
        group = "caddy";
        reloadServices = ["caddy.service"];
      };
    };

    services.caddy = {
      enable = true;
      openFirewall = true;
      email = "acme@ablz.au";
      globalConfig = ''
        servers {
          protocols h1 h2 h3
        }
      '';
      virtualHosts = builtins.listToAttrs (map (entry: {
          name = entry.host;
          value = {
            useACMEHost = certName;
            extraConfig = mkProxyConfig entry;
          };
        })
        cfg.entries);
      extraConfig = ''
        :443 {
          ${tlsLine}
          respond "Unknown host" 421
        }

        :80 {
          respond "Unknown host" 421
        }
      '';
    };

    # Caddy only needs the ACME certs and its own state, not /mnt.
    systemd.services.caddy.serviceConfig.TemporaryFileSystem = "/mnt";

    homelab.monitoring = {
      monitors = [
        {
          name = "Legacy edge Caddy";
          url = "https://router.ablz.au/";
        }
      ];
      errorPatterns = [
        {
          name = "Legacy edge Caddy config/runtime failure";
          unit = "caddy.service";
          pattern = "(?i)(panic|fatal|error loading config|certificate.*failed|bind: address already in use)";
          severity = "critical";
          summary = "Legacy edge Caddy is failing to serve its config";
          threshold = 0;
        }
      ];
    };
  };
}
