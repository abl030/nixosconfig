{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.monitoring;
  haveMonitors = cfg.monitors != [];

  monitorsJson = pkgs.writeTextFile {
    name = "homelab-monitors.json";
    text = builtins.toJSON cfg.monitors;
  };

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.uptime-kuma-api
    ps.requests
  ]);

  monitoringScript = pkgs.writeShellScript "homelab-monitoring-sync" ''
        set -euo pipefail

        cache_dir="/var/lib/homelab/monitoring"
        cache_file="$cache_dir/records.json"
        tmp_cache="$cache_dir/records.json.tmp"
        env_file=${lib.escapeShellArg config.sops.secrets."uptime-kuma/env".path}
        desired_file=${lib.escapeShellArg monitorsJson}
        kuma_url=${lib.escapeShellArg cfg.kumaUrl}

        mkdir -p "$cache_dir"

        if [[ ! -r "$env_file" ]]; then
          echo "homelab-monitoring-sync: env file not readable: $env_file" >&2
          exit 1
        fi

        kuma_user=$(${pkgs.gnugrep}/bin/grep -m1 '^KUMA_USERNAME=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2- || true)
        kuma_pass=$(${pkgs.gnugrep}/bin/grep -m1 '^KUMA_PASSWORD=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2- || true)

        if [[ -z "$kuma_user" || -z "$kuma_pass" ]]; then
          echo "homelab-monitoring-sync: missing KUMA_USERNAME/KUMA_PASSWORD in env file" >&2
          exit 1
        fi

        if [[ ! -f "$cache_file" ]]; then
          printf '{}' > "$cache_file"
        fi

        export KUMA_URL="$kuma_url"
        export KUMA_USER="$kuma_user"
        export KUMA_PASS="$kuma_pass"
        export DESIRED_FILE="$desired_file"
        export CACHE_FILE="$cache_file"
        export TMP_CACHE="$tmp_cache"

        ${pythonEnv}/bin/python - <<'PY'
    import json
    import os
    from uptime_kuma_api import UptimeKumaApi, MonitorType

    kuma_url = os.environ["KUMA_URL"]
    kuma_user = os.environ["KUMA_USER"]
    kuma_pass = os.environ["KUMA_PASS"]
    desired_path = os.environ["DESIRED_FILE"]
    cache_path = os.environ["CACHE_FILE"]
    tmp_path = os.environ["TMP_CACHE"]

    with open(desired_path, "r", encoding="utf-8") as fh:
        desired = json.load(fh)

    try:
        with open(cache_path, "r", encoding="utf-8") as fh:
            cache = json.load(fh)
    except FileNotFoundError:
        cache = {}

    updated = {}

    with UptimeKumaApi(kuma_url) as api:
        api.login(username=kuma_user, password=kuma_pass)
        monitors = api.get_monitors()
        by_url = {m.get("url"): m for m in monitors if m.get("url")}
        by_name = {m.get("name"): m for m in monitors if m.get("name")}

        for entry in desired:
            name = entry["name"]
            url = entry["url"]

            existing = by_url.get(url) or by_name.get(name)
            if existing:
                updated[url] = {
                    "name": name,
                    "url": url,
                    "monitorId": existing.get("id"),
                }
                continue

        resp = api.add_monitor(
            type=MonitorType.HTTP,
            name=name,
            url=url,
            accepted_statuscodes=["200-299", "300-399"],
            maxredirects=10,
            interval=60,
        )
            monitor_id = resp.get("monitorID") or resp.get("monitorId")
            updated[url] = {"name": name, "url": url, "monitorId": monitor_id}

    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(updated, fh, indent=2, sort_keys=True)
    os.replace(tmp_path, cache_path)
    PY
  '';
in {
  options.homelab.monitoring = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Uptime Kuma monitor registration sync.";
    };

    kumaUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://status.ablz.au";
      description = "Uptime Kuma base URL.";
    };

    authSecret = lib.mkOption {
      type = lib.types.anything;
      default = config.homelab.secrets.sopsFile "uptime-kuma.env";
      description = "SOPS file with KUMA_USERNAME/KUMA_PASSWORD.";
    };

    monitors = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Monitor display name.";
          };
          url = lib.mkOption {
            type = lib.types.str;
            description = "URL to monitor.";
          };
        };
      });
      default = [];
      description = "List of monitors to ensure in Uptime Kuma.";
    };
  };

  config = lib.mkIf (cfg.enable && haveMonitors) {
    sops.secrets."uptime-kuma/env" = {
      sopsFile = cfg.authSecret;
      format = "dotenv";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = lib.mkOrder 2000 [
      "d /var/lib/homelab/monitoring 0750 root root -"
    ];

    systemd.services.homelab-monitoring-sync = {
      description = "Sync Uptime Kuma monitors for local stacks";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = monitoringScript;
      };
    };
  };
}
