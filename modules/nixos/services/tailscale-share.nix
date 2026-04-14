{
  config,
  lib,
  pkgs,
  ...
}: let
  # Only enabled instances
  instances = lib.filterAttrs (_: v: v.enable) config.homelab.tailscaleShare;

  # Generate a Cloudflare DNS sync script for one instance.
  # After the tailscale container is online, queries its IP and upserts the A record.
  mkDnsSyncScript = name: cfg:
    pkgs.writeShellScript "tailscale-share-dns-sync-${name}" ''
      set -euo pipefail

      api="https://api.cloudflare.com/client/v4"
      zone_name="ablz.au"
      fqdn="${cfg.fqdn}"
      ttl=60

      # Extract token from the shared acme/cloudflare sops secret
      token_file=${lib.escapeShellArg config.sops.secrets."acme/cloudflare".path}
      raw_token=$(cat "$token_file")
      if [[ "$raw_token" == *CLOUDFLARE_DNS_API_TOKEN=* ]]; then
        token=$(printf '%s' "$raw_token" | ${pkgs.gnugrep}/bin/grep -m1 '^CLOUDFLARE_DNS_API_TOKEN=' | ${pkgs.coreutils}/bin/cut -d= -f2-)
      else
        token="$raw_token"
      fi
      token=$(printf '%s' "$token" | ${pkgs.coreutils}/bin/tr -d '\r\n')
      auth_header="Authorization: Bearer $token"
      content_header="Content-Type: application/json"

      # Wait for the tailscale container to be online and have an IP
      echo "tailscale-share-dns-sync-${name}: waiting for tailscale online..."
      max_wait=120
      count=0
      while ! ${config.virtualisation.podman.package}/bin/podman exec ts-${name} tailscale ip -4 &>/dev/null 2>&1; do
        count=$((count + 1))
        if [ "$count" -ge "$max_wait" ]; then
          echo "tailscale-share-dns-sync-${name}: timed out waiting for tailscale" >&2
          exit 1
        fi
        sleep 1
      done

      ts_ip=$(${config.virtualisation.podman.package}/bin/podman exec ts-${name} tailscale ip -4 | ${pkgs.coreutils}/bin/tr -d '\r\n')
      echo "tailscale-share-dns-sync-${name}: tailscale IP is $ts_ip"

      # Resolve zone ID
      zone_resp=$(${pkgs.curl}/bin/curl -fsS -H "$auth_header" -H "$content_header" \
        "$api/zones?name=$zone_name")
      zone_id=$(printf '%s' "$zone_resp" | ${pkgs.jq}/bin/jq -r '.result[0].id')
      if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        echo "tailscale-share-dns-sync-${name}: could not resolve zone id for $zone_name" >&2
        exit 1
      fi

      # Look for an existing A record
      records_resp=$(${pkgs.curl}/bin/curl -fsS -H "$auth_header" -H "$content_header" \
        "$api/zones/$zone_id/dns_records?type=A&name=$fqdn")
      record_id=$(printf '%s' "$records_resp" | ${pkgs.jq}/bin/jq -r '.result[0].id // ""')

      payload=$(${pkgs.jq}/bin/jq -n \
        --arg fqdn "$fqdn" --arg content "$ts_ip" --argjson ttl "$ttl" \
        '{type:"A",name:$fqdn,content:$content,ttl:$ttl,proxied:false}')

      if [[ -n "$record_id" ]]; then
        resp=$(${pkgs.curl}/bin/curl -fsS -X PUT -H "$auth_header" -H "$content_header" \
          --data "$payload" "$api/zones/$zone_id/dns_records/$record_id")
        if ! printf '%s' "$resp" | ${pkgs.jq}/bin/jq -e '.success' >/dev/null 2>&1; then
          echo "tailscale-share-dns-sync-${name}: PUT failed: $resp" >&2; exit 1
        fi
        echo "tailscale-share-dns-sync-${name}: updated $fqdn -> $ts_ip"
      else
        resp=$(${pkgs.curl}/bin/curl -fsS -X POST -H "$auth_header" -H "$content_header" \
          --data "$payload" "$api/zones/$zone_id/dns_records")
        if ! printf '%s' "$resp" | ${pkgs.jq}/bin/jq -e '.success' >/dev/null 2>&1; then
          echo "tailscale-share-dns-sync-${name}: POST failed: $resp" >&2; exit 1
        fi
        echo "tailscale-share-dns-sync-${name}: created $fqdn -> $ts_ip"
      fi
    '';

  # Generate a Caddyfile for one instance.
  # Uses CLOUDFLARE_DNS_API_TOKEN from the caddy container's environment.
  mkCaddyFile = name: cfg:
    pkgs.writeTextFile {
      name = "tailscale-share-${name}-Caddyfile";
      text = ''
        {
          acme_dns cloudflare {env.CLOUDFLARE_DNS_API_TOKEN}
        }

        ${cfg.fqdn} {
          reverse_proxy ${cfg.upstream}
        }
      '';
    };
in {
  options.homelab.tailscaleShare = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        enable = lib.mkEnableOption "per-service tailscale share for ${name}";

        fqdn = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN to expose this service at (e.g. overseer.ablz.au). A Cloudflare DNS A record is created pointing to the tailscale IP.";
        };

        upstream = lib.mkOption {
          type = lib.types.str;
          description = ''
            Local upstream URL to reverse-proxy. MUST use http://host.docker.internal:<port>
            — NOT 127.0.0.1. The caddy container shares the tailscale container's network
            namespace; 127.0.0.1 is the container loopback, not the host.
            Also set firewallPorts to open the port on the podman0 bridge.
          '';
        };

        dataDir = lib.mkOption {
          type = lib.types.str;
          description = "Persistent data directory for tailscale state and Caddy data.";
        };

        hostname = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Tailscale node hostname (defaults to the attrset key).";
        };

        firewallPorts = lib.mkOption {
          type = lib.types.listOf lib.types.port;
          default = [];
          description = ''
            TCP ports to open on the podman bridge interface (podman0) so the
            Caddy container can reach services on the host. Required because
            NixOS's firewall blocks container-to-host traffic by default.
            Typically the port your upstream service listens on.
          '';
        };
      };
    }));
    default = {};
    description = ''
      Per-service tailscale share instances. Each instance provisions:
      - A dedicated tailscale container with its own node identity and IP
      - A Caddy container sharing that network namespace (pinhole, not the whole VM)
      - A Cloudflare DNS A record synced to the tailscale IP on startup
      - ACME certs via Cloudflare DNS challenge

      Requires: homelab.podman.enable = true, sops secret "acme/cloudflare" on the host,
      and a per-instance sops secret "tailscale-share/<name>/authkey" (dotenv: TS_AUTHKEY=...).
    '';
  };

  config = lib.mkIf (instances != {}) {
    # Podman infrastructure (idempotent if already enabled by another module)
    homelab.podman.enable = lib.mkDefault true;

    # Open upstream ports on the podman bridge so containers can reach host services.
    # NixOS firewall blocks container-to-host traffic by default; caddy uses
    # host.docker.internal (10.88.0.1) which routes via the podman0 bridge.
    networking.firewall.interfaces.podman0.allowedTCPPorts =
      lib.concatLists (lib.mapAttrsToList (_: cfg: cfg.firewallPorts) instances);

    # Register containers for auto-update tracking
    homelab.podman.containers = lib.concatLists (lib.mapAttrsToList (name: _: [
        {
          unit = "podman-ts-${name}.service";
          image = "docker.io/tailscale/tailscale:latest";
        }
        {
          unit = "podman-caddy-${name}.service";
          image = "ghcr.io/caddybuilds/caddy-cloudflare:latest";
        }
      ])
      instances);

    # Persistent directories
    systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList (_: cfg: [
        "d ${cfg.dataDir} 0755 root root - -"
        "d ${cfg.dataDir}/ts-state 0755 root root - -"
        "d ${cfg.dataDir}/caddy-data 0755 root root - -"
        "d ${cfg.dataDir}/caddy-config 0755 root root - -"
      ])
      instances);

    # OCI containers — tailscale + caddy per instance
    virtualisation.oci-containers.containers = lib.mkMerge (lib.mapAttrsToList (name: cfg: {
        # Tailscale sidecar: joins tailnet with a dedicated identity
        "ts-${name}" = {
          image = "docker.io/tailscale/tailscale:latest";
          autoStart = true;
          pull = "newer";
          environment = {
            TS_STATE_DIR = "/var/lib/tailscale";
            TS_HOSTNAME = cfg.hostname;
            # Do not accept routes from other nodes — pinhole only
            TS_EXTRA_ARGS = "--accept-routes=false";
          };
          # Secret file format: TS_AUTHKEY=tskey-auth-...
          environmentFiles = [config.sops.secrets."tailscale-share/${name}/authkey".path];
          volumes = [
            "${cfg.dataDir}/ts-state:/var/lib/tailscale"
            "/dev/net/tun:/dev/net/tun"
          ];
          extraOptions = [
            # NET_ADMIN needed for tun device configuration; SYS_MODULE not needed
            # since /dev/net/tun is mounted directly (kernel module already loaded).
            "--cap-add=NET_ADMIN"
            # Containers joining this namespace inherit /etc/hosts from ts.
            # host.docker.internal lets caddy (sharing this namespace) reach services
            # on the host — 127.0.0.1 is the container loopback, not the host.
            "--add-host=host.docker.internal:host-gateway"
          ];
        };

        # Caddy: shares tailscale's network namespace, handles HTTPS + ACME
        "caddy-${name}" = {
          image = "ghcr.io/caddybuilds/caddy-cloudflare:latest";
          autoStart = true;
          pull = "newer";
          # Reuse the existing acme/cloudflare sops secret (CLOUDFLARE_DNS_API_TOKEN=...)
          environmentFiles = [config.sops.secrets."acme/cloudflare".path];
          volumes = [
            "${toString (mkCaddyFile name cfg)}:/etc/caddy/Caddyfile:ro"
            "${cfg.dataDir}/caddy-data:/data"
            "${cfg.dataDir}/caddy-config:/config"
          ];
          extraOptions = [
            # Share the tailscale container's network namespace — caddy binds on the TS IP.
            # Containers joining a namespace cannot set --add-host; host resolution is
            # inherited from the ts container's /etc/hosts (set via --add-host on ts above).
            "--network=container:ts-${name}"
          ];
          dependsOn = ["ts-${name}"];
        };
      })
      instances);

    # Systemd service overrides + DNS sync
    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: cfg: {
        # DNS sync: wait for tailscale online, upsert Cloudflare A record
        "tailscale-share-dns-sync-${name}" = {
          description = "Sync Cloudflare DNS for ${name} tailscale share (${cfg.fqdn})";
          after = ["podman-ts-${name}.service" "network-online.target"];
          wants = ["network-online.target"];
          requires = ["podman-ts-${name}.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = mkDnsSyncScript name cfg;
          };
        };
      })
      instances);

    # Per-instance sops secrets for tailscale auth keys
    # Secret file must be dotenv format: TS_AUTHKEY=tskey-auth-...
    sops.secrets = lib.mkMerge (lib.mapAttrsToList (name: _: {
        "tailscale-share/${name}/authkey" = {
          sopsFile = config.homelab.secrets.sopsFile "${name}-tailscale-authkey.env";
          format = "dotenv";
          mode = "0400";
        };
      })
      instances);
  };
}
