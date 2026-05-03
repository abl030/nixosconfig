{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.monitoring;
  haveMonitoringConfig = cfg.monitors != [] || cfg.maintenanceWindows != [];

  monitorsJson = pkgs.writeTextFile {
    name = "homelab-monitors.json";
    text = builtins.toJSON cfg.monitors;
  };

  maintenancesJson = pkgs.writeTextFile {
    name = "homelab-maintenance-windows.json";
    text = builtins.toJSON cfg.maintenanceWindows;
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
        maint_cache_file="$cache_dir/maintenance.json"
        tmp_maint_cache="$cache_dir/maintenance.json.tmp"
        env_file=${lib.escapeShellArg config.sops.secrets."uptime-kuma/env".path}
        desired_file=${lib.escapeShellArg monitorsJson}
        maintenances_file=${lib.escapeShellArg maintenancesJson}
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

        # Source additional secret env files for basicAuthUserEnv/basicAuthPassEnv
        ${lib.concatMapStringsSep "\n    " (f: ''
      if [[ -r ${lib.escapeShellArg f} ]]; then
        set -a
        . ${lib.escapeShellArg f}
        set +a
      fi'')
    cfg.secretEnvFiles}

        export KUMA_URL="$kuma_url"
        export KUMA_USER="$kuma_user"
        export KUMA_PASS="$kuma_pass"
        export DESIRED_FILE="$desired_file"
        export MAINTENANCES_FILE="$maintenances_file"
        export CACHE_FILE="$cache_file"
        export TMP_CACHE="$tmp_cache"
        export MAINT_CACHE_FILE="$maint_cache_file"
        export TMP_MAINT_CACHE="$tmp_maint_cache"

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
    from uptime_kuma_api import UptimeKumaApi, MonitorType, AuthMethod, MaintenanceStrategy
    from uptime_kuma_api.exceptions import UptimeKumaException

    kuma_url = os.environ["KUMA_URL"]
    kuma_user = os.environ["KUMA_USER"]
    kuma_pass = os.environ["KUMA_PASS"]
    desired_path = os.environ["DESIRED_FILE"]
    maintenances_path = os.environ["MAINTENANCES_FILE"]
    cache_path = os.environ["CACHE_FILE"]
    tmp_path = os.environ["TMP_CACHE"]
    maint_cache_path = os.environ["MAINT_CACHE_FILE"]
    tmp_maint_cache_path = os.environ["TMP_MAINT_CACHE"]

    with open(desired_path, "r", encoding="utf-8") as fh:
        desired = json.load(fh)

    with open(maintenances_path, "r", encoding="utf-8") as fh:
        desired_maintenances = json.load(fh)

    try:
        with open(cache_path, "r", encoding="utf-8") as fh:
            cache = json.load(fh)
    except FileNotFoundError:
        cache = {}

    try:
        with open(maint_cache_path, "r", encoding="utf-8") as fh:
            maint_cache = json.load(fh)
    except FileNotFoundError:
        maint_cache = {}

    def parse_hhmm(value: str) -> dict:
        h, m = value.split(":", 1)
        return {"hours": int(h), "minutes": int(m)}

    def sync_once() -> tuple:
        updated = {}
        updated_maint = {}
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
                # Resolve env var references (basicAuthUserEnv/basicAuthPassEnv)
                if entry.get("basicAuthUserEnv"):
                    basic_auth_user = os.environ.get(entry["basicAuthUserEnv"], basic_auth_user)
                if entry.get("basicAuthPassEnv"):
                    basic_auth_pass = os.environ.get(entry["basicAuthPassEnv"], basic_auth_pass)
                interval = entry.get("interval", 60)
                maxretries = int(entry.get("maxretries", 10))
                retry_interval = int(entry.get("retryInterval", 60))
                resend_interval = int(entry.get("resendInterval", 240))

                if mon_type == "json-query":
                    kuma_type = MonitorType.JSON_QUERY
                else:
                    kuma_type = MonitorType.HTTP

                # Build kwargs common to add/edit. `type` MUST be in here so
                # edit_monitor() actually updates an existing monitor's type
                # when the desired type changes (e.g. http → json-query).
                # Previously type was only passed on the add path, so a monitor
                # created as "http" stayed "http" forever and the json-query
                # fields were silently orphaned.
                common_kwargs = dict(
                    type=kuma_type,
                    name=name,
                    url=url,
                    ignoreTls=ignore_tls,
                    accepted_statuscodes=accepted_codes,
                    notificationIDList=notification_ids,
                    maxredirects=10,
                    interval=interval,
                    maxretries=maxretries,
                    retryInterval=retry_interval,
                    resendInterval=resend_interval,
                )
                if headers_json:
                    common_kwargs["headers"] = headers_json
                if basic_auth_user:
                    common_kwargs["basic_auth_user"] = basic_auth_user
                    common_kwargs["authMethod"] = AuthMethod.HTTP_BASIC
                if basic_auth_pass:
                    common_kwargs["basic_auth_pass"] = basic_auth_pass
                if mon_type == "json-query":
                    common_kwargs["method"] = method
                    common_kwargs["jsonPathOperator"] = "=="
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
                        str(existing.get("type") or "") != mon_type
                        or existing.get("name") != name
                        or existing.get("url") != url
                        or bool(existing.get("ignoreTls")) != ignore_tls
                        or (host_header and existing.get("headers") != headers_json)
                        or existing_codes != desired_codes
                        or existing_notifications != desired_notifications
                        or existing.get("interval") != interval
                        or int(existing.get("maxretries") or 0) != maxretries
                        or int(existing.get("retryInterval") or 0) != retry_interval
                        or int(existing.get("resendInterval") or 0) != resend_interval
                        or (json_path and existing.get("jsonPath") != json_path)
                        or (expected_value and str(existing.get("expectedValue", "")) != expected_value)
                        or (basic_auth_user and str(existing.get("authMethod", "")) != str(AuthMethod.HTTP_BASIC))
                        or (basic_auth_user and existing.get("basic_auth_user") != basic_auth_user)
                        or (basic_auth_pass and existing.get("basic_auth_pass") != basic_auth_pass)
                        or (mon_type == "json-query" and existing.get("jsonPathOperator") != "==")
                    )
                    if needs_update:
                        api.edit_monitor(monitor_id, **common_kwargs)
                    updated[url] = {"name": name, "url": url, "monitorId": monitor_id}
                    continue

                # Uptime Kuma 2.x requires conditions (NOT NULL).
                # uptime-kuma-api 1.2.1 doesn't support it, so inject
                # into the built data and call the socket directly.
                from uptime_kuma_api.api import _convert_monitor_input, _check_arguments_monitor, Event
                data = api._build_monitor_data(**common_kwargs)
                _convert_monitor_input(data)
                _check_arguments_monitor(data)
                data["conditions"] = ""
                with api.wait_for_event(Event.MONITOR_LIST):
                    resp = api._call('add', data)
                monitor_id = resp.get("monitorID") or resp.get("monitorId")
                updated[url] = {"name": name, "url": url, "monitorId": monitor_id}

            # ---------------------------------------------------------------
            # Maintenance windows
            # ---------------------------------------------------------------
            if desired_maintenances:
                # Refresh monitor list in case we just added new ones.
                all_monitors = api.get_monitors()
                name_to_id = {m.get("name"): m.get("id") for m in all_monitors if m.get("name")}
                all_ids = [m.get("id") for m in all_monitors if m.get("id") is not None]

                existing_maint = api.get_maintenances() or []
                existing_by_title = {m.get("title"): m for m in existing_maint if m.get("title")}

                for entry in desired_maintenances:
                    title = entry["title"]
                    description = entry.get("description", "")
                    active = bool(entry.get("active", True))
                    timezone_option = entry.get("timezone", "Australia/Perth")
                    strategy_str = entry.get("strategy", "recurring-interval")
                    interval_day = int(entry.get("intervalDay", 1))
                    start_time = entry.get("startTime", "00:00")
                    end_time = entry.get("endTime", "01:00")
                    start_date = entry.get("startDate", "2026-01-01 00:00:00")
                    end_date = entry.get("endDate", "2099-12-31 23:59:59")
                    applies_all = bool(entry.get("appliesToAllMonitors", True))
                    monitor_names = entry.get("monitorNames", []) or []

                    if strategy_str != "recurring-interval":
                        raise UptimeKumaException(
                            f"maintenance window {title!r}: only recurring-interval strategy is supported"
                        )

                    time_range = [parse_hhmm(start_time), parse_hhmm(end_time)]
                    date_range = [start_date, end_date]

                    maint_kwargs = dict(
                        title=title,
                        description=description,
                        strategy=MaintenanceStrategy.RECURRING_INTERVAL,
                        active=active,
                        intervalDay=interval_day,
                        dateRange=date_range,
                        timeRange=time_range,
                        timezoneOption=timezone_option,
                        weekdays=[],
                        daysOfMonth=[],
                    )

                    existing = existing_by_title.get(title)
                    if existing:
                        maint_id = existing.get("id")
                        # Always edit — cheap and guarantees convergence.
                        api.edit_maintenance(maint_id, **maint_kwargs)
                    else:
                        resp = api.add_maintenance(**maint_kwargs)
                        maint_id = resp.get("maintenanceID") or resp.get("maintenanceId") or resp.get("id")
                        if maint_id is None:
                            # Re-fetch to discover the id.
                            for m in api.get_maintenances() or []:
                                if m.get("title") == title:
                                    maint_id = m.get("id")
                                    break
                        if maint_id is None:
                            raise UptimeKumaException(
                                f"maintenance window {title!r}: could not determine id after create"
                            )

                    # Attach monitors (replaces the existing attachment set).
                    if applies_all:
                        attach_ids = list(all_ids)
                    else:
                        attach_ids = [name_to_id[n] for n in monitor_names if n in name_to_id]
                    monitor_payload = [{"id": mid} for mid in attach_ids if mid is not None]
                    api.add_monitor_maintenance(maint_id, monitor_payload)

                    updated_maint[title] = {
                        "title": title,
                        "maintenanceId": maint_id,
                        "monitorCount": len(monitor_payload),
                    }

        return updated, updated_maint

    last_error = None
    for attempt in range(3):
        try:
            monitor_result, maint_result = sync_once()
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(monitor_result, fh, indent=2, sort_keys=True)
            os.replace(tmp_path, cache_path)
            with open(tmp_maint_cache_path, "w", encoding="utf-8") as fh:
                json.dump(maint_result, fh, indent=2, sort_keys=True)
            os.replace(tmp_maint_cache_path, maint_cache_path)
            last_error = None
            break
        except (socketio.exceptions.TimeoutError, socketio.exceptions.BadNamespaceError, UptimeKumaException) as exc:
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

    secretEnvFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Paths to SOPS-decrypted env files sourced at runtime for basicAuthUserEnv/basicAuthPassEnv.";
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
            description = "Basic auth username (literal value, or use basicAuthUserEnv for SOPS).";
          };
          basicAuthPass = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Basic auth password (literal value, or use basicAuthPassEnv for SOPS).";
          };
          basicAuthUserEnv = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Env var name for basic auth username (resolved at runtime from secretEnvFiles).";
          };
          basicAuthPassEnv = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Env var name for basic auth password (resolved at runtime from secretEnvFiles).";
          };
          interval = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Check interval in seconds.";
          };
          maxretries = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = ''
              Number of consecutive failed checks before the monitor is marked
              DOWN and a notification fires. At the default interval of 60s,
              maxretries=10 means a blip needs ~10 minutes of continuous
              failure before alerting — this suppresses the nightly rebuild
              noise without hiding real outages.
            '';
          };
          retryInterval = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Seconds between retries after a failed check.";
          };
          resendInterval = lib.mkOption {
            type = lib.types.int;
            default = 240;
            description = ''
              Number of heartbeats between re-notifications while a monitor is
              still DOWN. At interval=60s, 240 ≈ 4 hours — persistent outages
              re-page so you notice if you missed the first ping.
            '';
          };
        };
      });
      default = [];
      description = "List of monitors to ensure in Uptime Kuma.";
    };

    maintenanceWindows = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
            description = "Unique title — used as the key to find/update windows in Kuma.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Human description shown in the Kuma UI.";
          };
          active = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the window is active.";
          };
          timezone = lib.mkOption {
            type = lib.types.str;
            default = "Australia/Perth";
            description = "Timezone the startTime/endTime are interpreted in.";
          };
          strategy = lib.mkOption {
            type = lib.types.enum ["recurring-interval"];
            default = "recurring-interval";
            description = "Only recurring-interval is currently supported.";
          };
          intervalDay = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Run the window every N days.";
          };
          startTime = lib.mkOption {
            type = lib.types.str;
            description = "Start time of the daily window, format HH:MM.";
          };
          endTime = lib.mkOption {
            type = lib.types.str;
            description = "End time of the daily window, format HH:MM.";
          };
          startDate = lib.mkOption {
            type = lib.types.str;
            default = "2026-01-01 00:00:00";
            description = "Date from which the recurring window applies.";
          };
          endDate = lib.mkOption {
            type = lib.types.str;
            default = "2099-12-31 23:59:59";
            description = "Date after which the recurring window no longer applies.";
          };
          appliesToAllMonitors = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              If true, attach every monitor known to Kuma to this window.
              If false, only attach monitors listed in `monitorNames`.
            '';
          };
          monitorNames = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Monitor names (match `homelab.monitoring.monitors.*.name`). Only used when appliesToAllMonitors = false.";
          };
        };
      });
      default = [];
      description = ''
        Declarative Uptime Kuma maintenance windows. Use these to silence
        expected fleet-wide noise (e.g. nightly rebuilds) so real alerts
        aren't drowned out. Define each window exactly once — on the host
        that runs Uptime Kuma — to avoid cross-host races.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && haveMonitoringConfig) {
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
      # Re-run on every rebuild when the desired monitor/maintenance set
      # changes. Without these, the oneshot goes inactive after its first
      # boot-time run and switch-to-configuration never triggers it again —
      # new homelab.monitoring.monitors entries would never land in Kuma.
      restartTriggers = [monitorsJson maintenancesJson];
      serviceConfig = {
        Type = "oneshot";
        # RemainAfterExit keeps the unit `active (exited)` so
        # switch-to-configuration treats it as live and honours
        # restartIfChanged (default true) on derivation changes.
        RemainAfterExit = true;
        ExecStart = monitoringScript;
      };
    };
  };
}
