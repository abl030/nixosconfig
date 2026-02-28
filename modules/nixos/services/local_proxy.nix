{
  lib,
  config,
  hostConfig,
  pkgs,
  ...
}: let
  cfg = config.homelab.localProxy;

  haveHosts = cfg.hosts != [];
  hostEntries = cfg.hosts;

  hostsJson = pkgs.writeTextFile {
    name = "local-proxy-hosts.json";
    text = builtins.toJSON hostEntries;
  };

  dnsSyncScript = pkgs.writeShellScript "homelab-dns-sync" ''
    set -euo pipefail

    api="https://api.cloudflare.com/client/v4"
    zone_name="ablz.au"
    ttl=60
    local_ip=${lib.escapeShellArg (cfg.localIp or "")}

    cache_dir="/var/lib/homelab/dns"
    zone_cache="$cache_dir/zone-id"
    records_cache="$cache_dir/records.json"
    hosts_json=${hostsJson}

    mkdir -p "$cache_dir"

    token_file=${lib.escapeShellArg config.sops.secrets."acme/cloudflare".path}
    if [[ ! -r "$token_file" ]]; then
      echo "homelab-dns-sync: token file not readable: $token_file" >&2
      exit 1
    fi

    raw_token=$(cat "$token_file")
    if [[ "$raw_token" == *CLOUDFLARE_DNS_API_TOKEN=* ]]; then
      token=$(printf '%s' "$raw_token" | ${pkgs.gnugrep}/bin/grep -m1 '^CLOUDFLARE_DNS_API_TOKEN=' | ${pkgs.coreutils}/bin/cut -d= -f2-)
    else
      token="$raw_token"
    fi
    token=$(printf '%s' "$token" | ${pkgs.coreutils}/bin/tr -d '\r\n')

    auth_header="Authorization: Bearer $token"
    content_header="Content-Type: application/json"

    api_calls_file="$cache_dir/api-calls-run"
    : > "$api_calls_file"

    cf_request() {
      local method=$1
      local url=$2
      local data=''${3:-}
      local resp
      printf '.' >> "$api_calls_file"
      if [[ -n "$data" ]]; then
        resp=$(${pkgs.curl}/bin/curl -fsS -X "$method" -H "$auth_header" -H "$content_header" --data "$data" "$url")
      else
        resp=$(${pkgs.curl}/bin/curl -fsS -X "$method" -H "$auth_header" -H "$content_header" "$url")
      fi
      local ok
      ok=$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.success')
      if [[ "$ok" != "true" ]]; then
        echo "homelab-dns-sync: Cloudflare API error for $url" >&2
        printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.errors[]?.message' >&2 || true
        exit 1
      fi
      printf '%s' "$resp"
    }

    if [[ -s "$zone_cache" ]]; then
      zone_id=$(cat "$zone_cache")
    else
      resp=$(cf_request GET "$api/zones?name=$zone_name")
      zone_id=$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.result[0].id')
      if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        echo "homelab-dns-sync: could not resolve zone id for $zone_name" >&2
        exit 1
      fi
      printf '%s' "$zone_id" > "$zone_cache"
    fi

    if [[ ! -f "$records_cache" ]]; then
      printf '{}' > "$records_cache"
    fi

    tmp_cache="$records_cache.tmp"
    cp "$records_cache" "$tmp_cache"

    desired_hosts=$(${pkgs.jq}/bin/jq -r '.[].host' "$hosts_json" | ${pkgs.coreutils}/bin/sort -u)

    while read -r cached_host; do
      if ! printf '%s\n' "$desired_hosts" | ${pkgs.gnugrep}/bin/grep -qx "$cached_host"; then
        record_id=$(${pkgs.jq}/bin/jq -r --arg host "$cached_host" '.[$host].recordId // ""' "$records_cache")
        if [[ -n "$record_id" ]]; then
          cf_request DELETE "$api/zones/$zone_id/dns_records/$record_id" >/dev/null
          echo "homelab-dns-sync: removed $cached_host"
        fi
        ${pkgs.jq}/bin/jq --arg host "$cached_host" 'del(.[$host])' "$tmp_cache" > "$tmp_cache.next"
        mv "$tmp_cache.next" "$tmp_cache"
      fi
    done < <(${pkgs.jq}/bin/jq -r 'keys[]' "$records_cache")

    while read -r entry; do
      host=$(printf '%s' "$entry" | ${pkgs.jq}/bin/jq -r '.host')
      if [[ -z "$host" || "$host" == "null" ]]; then
        continue
      fi

      cache_ip=$(${pkgs.jq}/bin/jq -r --arg host "$host" '.[$host].ip // ""' "$records_cache")
      cache_ttl=$(${pkgs.jq}/bin/jq -r --arg host "$host" '.[$host].ttl // ""' "$records_cache")
      cache_id=$(${pkgs.jq}/bin/jq -r --arg host "$host" '.[$host].recordId // ""' "$records_cache")

      if [[ "$cache_ip" == "$local_ip" && "$cache_ttl" == "$ttl" && -n "$cache_id" ]]; then
        echo "homelab-dns-sync: $host up-to-date (cache)"
        continue
      fi

      record_id="$cache_id"
      if [[ -z "$record_id" ]]; then
        resp=$(cf_request GET "$api/zones/$zone_id/dns_records?type=A&name=$host")
        record_id=$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.result[0].id // ""')
      fi

      payload=$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":false}' "$host" "$local_ip" "$ttl")

      if [[ -n "$record_id" ]]; then
        cf_request PUT "$api/zones/$zone_id/dns_records/$record_id" "$payload" >/dev/null
      else
        resp=$(cf_request POST "$api/zones/$zone_id/dns_records" "$payload")
        record_id=$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.result.id')
      fi

      if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        echo "homelab-dns-sync: failed to resolve record id for $host" >&2
        exit 1
      fi

      ${pkgs.jq}/bin/jq --arg host "$host" --arg ip "$local_ip" --arg ttl "$ttl" --arg id "$record_id" \
        '. + {($host): {ip: $ip, ttl: ($ttl|tonumber), recordId: $id}}' \
        "$tmp_cache" > "$tmp_cache.next"
      mv "$tmp_cache.next" "$tmp_cache"

      echo "homelab-dns-sync: ensured $host -> $local_ip"
    done < <(${pkgs.jq}/bin/jq -c '.[]' "$hosts_json")

    mv "$tmp_cache" "$records_cache"

    api_calls=$(${pkgs.coreutils}/bin/wc -c < "$api_calls_file" | ${pkgs.coreutils}/bin/tr -d '[:space:]')
    count_file="$cache_dir/api-call-count"
    total=0
    if [[ -s "$count_file" ]]; then
      total=$(cat "$count_file")
    fi
    total=$((total + api_calls))
    printf '%s' "$total" > "$count_file"
    echo "homelab-dns-sync: cloudflare_api_calls=$api_calls total=$total"
  '';

  dnsValidateScript = pkgs.writeShellScript "homelab-dns-validate" ''
    set -euo pipefail

    local_ip=${lib.escapeShellArg (cfg.localIp or "")}
    cache="/var/lib/homelab/dns/records.json"

    if [[ ! -f "$cache" ]]; then
      echo "homelab-dns-validate: no cache file, nothing to validate"
      exit 0
    fi

    invalidated=0

    for host in $(${pkgs.jq}/bin/jq -r 'keys[]' "$cache"); do
      actual=$(${pkgs.dnsutils}/bin/dig +short "$host" | ${pkgs.coreutils}/bin/head -1)
      if [[ -z "$actual" ]]; then
        echo "homelab-dns-validate: $host did not resolve — skipping"
        continue
      fi
      if [[ "$actual" != "$local_ip" ]]; then
        echo "homelab-dns-validate: $host resolves to $actual, expected $local_ip — invalidating"
        ${pkgs.jq}/bin/jq --arg host "$host" 'del(.[$host])' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
        invalidated=$((invalidated + 1))
      fi
    done

    echo "homelab-dns-validate: checked $(${pkgs.jq}/bin/jq 'length' "$cache") entries, invalidated $invalidated"
  '';

  vhosts = builtins.listToAttrs (map (entry: let
      websocketConfig =
        if entry.websocket or false
        then ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
        ''
        else "";
      maxBodySizeConfig =
        if entry.maxBodySize or null != null
        then "client_max_body_size ${entry.maxBodySize};"
        else "";
    in {
      name = entry.host;
      value = {
        useACMEHost = entry.host;
        onlySSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString entry.port}";
          extraConfig = ''
            ${maxBodySizeConfig}
            ${websocketConfig}
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Port 443;
            proxy_redirect http://$host/ https://$host/;
            proxy_redirect http:// https://;
          '';
        };
      };
    })
    hostEntries);

  acmeCerts = builtins.listToAttrs (map (entry: {
      name = entry.host;
      value = {domain = entry.host;};
    })
    hostEntries);
in {
  options.homelab.localProxy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable per-host local proxy + Cloudflare DNS sync for stacks.";
    };

    localIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = hostConfig.localIp or null;
      description = "Local IPv4 for host A records (e.g., 192.168.1.29).";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Hostname for local proxy (e.g., immich.ablz.au).";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "Local service port to proxy (e.g., 2283).";
          };
          websocket = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable websocket proxy headers for this host.";
          };
          maxBodySize = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Nginx client_max_body_size for this host (e.g., \"0\" for unlimited, \"50G\"). Null uses nginx default (1m).";
          };
        };
      });
      default = [];
      description = "List of hostnames and proxy ports for local per-host routing.";
    };
  };

  config = lib.mkIf (cfg.enable && haveHosts) {
    assertions = [
      {
        assertion = cfg.localIp != null && cfg.localIp != "";
        message = "homelab.localProxy.localIp must be set when localProxy.hosts is non-empty.";
      }
    ];

    homelab.nginx.enable = true;

    security.acme.certs = acmeCerts;

    services.nginx.virtualHosts = vhosts;

    systemd = {
      tmpfiles.rules = lib.mkOrder 2000 [
        "d /var/lib/homelab/dns 0750 root root -"
      ];

      services.homelab-dns-sync = {
        description = "Sync local proxy DNS records in Cloudflare";
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = dnsSyncScript;
          StateDirectory = "homelab/dns";
          StateDirectoryMode = "0750";
          ReadWritePaths = ["/var/lib/homelab/dns"];
        };
      };

      services.homelab-dns-validate = {
        description = "Validate DNS cache against actual resolution";
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = dnsValidateScript;
          ExecStartPost = "${pkgs.systemd}/bin/systemctl start homelab-dns-sync.service";
          ReadWritePaths = ["/var/lib/homelab/dns"];
        };
      };

      timers.homelab-dns-validate = {
        description = "Nightly DNS cache validation";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-* 02:00:00";
          Persistent = true;
        };
      };
    };

    system.activationScripts.homelabDnsSync.text = ''
      if ${pkgs.coreutils}/bin/test -x ${dnsSyncScript}; then
        ${pkgs.systemd}/bin/systemctl daemon-reload || true
        if ${pkgs.systemd}/bin/systemctl list-unit-files | ${pkgs.gnugrep}/bin/grep -q '^homelab-dns-sync.service'; then
          ${pkgs.systemd}/bin/systemctl start homelab-dns-sync.service || true
        fi
      fi
    '';
  };
}
