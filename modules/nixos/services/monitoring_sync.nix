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
    ps.websocket-client
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

        max_wait_seconds=60
        waited=0
        while ! ${pkgs.curl}/bin/curl -fsS --connect-timeout 3 --max-time 5 "$kuma_url/api/status" >/dev/null 2>&1; do
          if [[ $waited -ge $max_wait_seconds ]]; then
            echo "homelab-monitoring-sync: Uptime Kuma not reachable at $kuma_url" >&2
            exit 1
          fi
          sleep 2
          waited=$((waited + 2))
        done

        ${pythonEnv}/bin/python - <<'PY'
    import json
    import os
    import time
    import socketio
    from uptime_kuma_api import UptimeKumaApi, MonitorType
    from uptime_kuma_api.exceptions import UptimeKumaException

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

    def sync_once() -> dict:
        updated = {}
        with UptimeKumaApi(kuma_url, timeout=30) as api:
            api.login(username=kuma_user, password=kuma_pass)
            monitors = api.get_monitors()
            notifications = api.get_notifications()
            default_notification_ids = [
                n["id"] for n in notifications if n.get("isDefault")
            ]
            if not default_notification_ids:
                raise UptimeKumaException("no default notification configured in Uptime Kuma")

            by_url = {m.get("url"): m for m in monitors if m.get("url")}
            by_name = {m.get("name"): m for m in monitors if m.get("name")}

            for entry in desired:
                name = entry["name"]
                url = entry["url"]
                mon_type = entry.get("type", "http")
                host_header = entry.get("hostHeader")
                ignore_tls = bool(entry.get("ignoreTls", False))
                accepted_codes = entry.get("acceptedStatusCodes") or ["200-299", "300-399"]
                notification_ids = default_notification_ids
                headers_json = json.dumps({"Host": host_header}) if host_header else None
                json_path = entry.get("jsonPath")
                expected_value = entry.get("expectedValue")
                method = entry.get("method", "GET")
                basic_auth_user = entry.get("basicAuthUser")
                basic_auth_pass = entry.get("basicAuthPass")
                interval = entry.get("interval", 60)

                if mon_type == "json-query":
                    kuma_type = MonitorType.JSON_QUERY
                else:
                    kuma_type = MonitorType.HTTP

                # Build kwargs common to add/edit
                common_kwargs = dict(
                    name=name,
                    url=url,
                    ignoreTls=ignore_tls,
                    accepted_statuscodes=accepted_codes,
                    notificationIDList=notification_ids,
                    maxredirects=10,
                    interval=interval,
                )
                if headers_json:
                    common_kwargs["headers"] = headers_json
                if basic_auth_user:
                    common_kwargs["basic_auth_user"] = basic_auth_user
                if basic_auth_pass:
                    common_kwargs["basic_auth_pass"] = basic_auth_pass
                if mon_type == "json-query":
                    common_kwargs["method"] = method
                    if json_path:
                        common_kwargs["jsonPath"] = json_path
                    if expected_value:
                        common_kwargs["expectedValue"] = expected_value

                existing = by_url.get(url) or by_name.get(name)
                if existing:
                    monitor_id = existing.get("id")
                    existing_codes = existing.get("accepted_statuscodes") or existing.get("acceptedStatusCodes") or []
                    existing_notifications = existing.get("notificationIDList") or []
                    if isinstance(existing_notifications, dict):
                        existing_notifications = [int(i) for i in existing_notifications.keys()]
                    try:
                        existing_codes = sorted(existing_codes)
                    except TypeError:
                        existing_codes = existing_codes
                    try:
                        desired_codes = sorted(accepted_codes)
                    except TypeError:
                        desired_codes = accepted_codes
                    try:
                        desired_notifications = sorted(notification_ids)
                    except TypeError:
                        desired_notifications = notification_ids
                    needs_update = (
                        existing.get("name") != name
                        or existing.get("url") != url
                        or bool(existing.get("ignoreTls")) != ignore_tls
                        or (host_header and existing.get("headers") != headers_json)
                        or existing_codes != desired_codes
                        or existing_notifications != desired_notifications
                        or existing.get("interval") != interval
                        or (json_path and existing.get("jsonPath") != json_path)
                        or (expected_value and str(existing.get("expectedValue", "")) != expected_value)
                    )
                    if needs_update:
                        api.edit_monitor(monitor_id, **common_kwargs)
                    updated[url] = {"name": name, "url": url, "monitorId": monitor_id}
                    continue

                resp = api.add_monitor(type=kuma_type, **common_kwargs)
                monitor_id = resp.get("monitorID") or resp.get("monitorId")
                updated[url] = {"name": name, "url": url, "monitorId": monitor_id}

        return updated

    last_error = None
    for attempt in range(3):
        try:
            result = sync_once()
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(result, fh, indent=2, sort_keys=True)
            os.replace(tmp_path, cache_path)
            last_error = None
            break
        except (socketio.exceptions.BadNamespaceError, UptimeKumaException) as exc:
            last_error = exc
            time.sleep(2 * (attempt + 1))

    if last_error is not None:
        raise last_error
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

    apiKeySecret = lib.mkOption {
      type = lib.types.anything;
      default = config.homelab.secrets.sopsFile "uptime-kuma-api.env";
      description = "SOPS file with KUMA_API_KEY for metrics access.";
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
          hostHeader = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional Host header override (e.g., ping.ablz.au).";
          };
          ignoreTls = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Ignore TLS validation errors for the monitor.";
          };
          acceptedStatusCodes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["200-299" "300-399"];
            description = "Accepted HTTP status code ranges for the monitor.";
          };
          type = lib.mkOption {
            type = lib.types.enum ["http" "json-query"];
            default = "http";
            description = "Monitor type: http or json-query.";
          };
          jsonPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "JSONata expression for json-query monitors.";
          };
          expectedValue = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Expected value for json-query monitors.";
          };
          method = lib.mkOption {
            type = lib.types.str;
            default = "GET";
            description = "HTTP method.";
          };
          basicAuthUser = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Basic auth username.";
          };
          basicAuthPass = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Basic auth password.";
          };
          interval = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Check interval in seconds.";
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

    sops.secrets."uptime-kuma/api" = {
      sopsFile = cfg.apiKeySecret;
      format = "dotenv";
      key = "KUMA_API_KEY";
      owner = config.homelab.user;
      mode = "0400";
    };

    environment.sessionVariables.KUMA_API_KEY_FILE =
      config.sops.secrets."uptime-kuma/api".path;

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
