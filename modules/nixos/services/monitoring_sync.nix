{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.monitoring;

  # Auto-materialise deepProbes into push-type monitors so the existing
  # sync code provisions them in Kuma. Users only ever declare deepProbes;
  # the monitors entry is generated.
  deepProbeMonitors =
    map (probe: {
      inherit (probe) name maxretries retryInterval resendInterval;
      url = "";
      type = "push";
      interval = probe.intervalSecs;
      hostHeader = null;
      ignoreTls = false;
      acceptedStatusCodes = ["200-299"];
      jsonPath = null;
      expectedValue = null;
      method = "GET";
      basicAuthUser = null;
      basicAuthPass = null;
      basicAuthUserEnv = null;
      basicAuthPassEnv = null;
    })
    cfg.deepProbes;

  allMonitors = cfg.monitors ++ deepProbeMonitors;

  # Safe basename for state file lookup — must match the python
  # write_push_url() regex/lower transform.
  probeSlug = name:
    lib.toLower (
      builtins.replaceStrings
      ["/" " " "(" ")" "—" "[" "]"]
      ["-" "-" "" "" "-" "" ""]
      name
    );

  haveMonitoringConfig =
    allMonitors != [] || cfg.maintenanceWindows != [];

  monitorsJson = pkgs.writeTextFile {
    name = "homelab-monitors.json";
    text = builtins.toJSON allMonitors;
  };

  notificationsJson = pkgs.writeTextFile {
    name = "homelab-notifications.json";
    text = builtins.toJSON cfg.notifications;
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
        notifications_file=${lib.escapeShellArg notificationsJson}
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
        export NOTIFICATIONS_FILE="$notifications_file"
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
    notifications_path = os.environ["NOTIFICATIONS_FILE"]
    cache_path = os.environ["CACHE_FILE"]
    tmp_path = os.environ["TMP_CACHE"]
    maint_cache_path = os.environ["MAINT_CACHE_FILE"]
    tmp_maint_cache_path = os.environ["TMP_MAINT_CACHE"]

    with open(desired_path, "r", encoding="utf-8") as fh:
        desired = json.load(fh)

    with open(maintenances_path, "r", encoding="utf-8") as fh:
        desired_maintenances = json.load(fh)

    with open(notifications_path, "r", encoding="utf-8") as fh:
        desired_notifications_config = json.load(fh)

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

    def write_push_url(api, monitor_id, name, kuma_url):
        """Look up the push monitor by id, read its pushToken, write the
        push URL to /var/lib/homelab/monitoring/push-urls/<safe-name>.url.
        deep-probe oneshots read this file at runtime."""
        import re
        import pathlib
        # Re-fetch monitor to get the pushToken — get_monitor includes it.
        mon = api.get_monitor(monitor_id)
        token = mon.get("pushToken") or mon.get("push_token")
        if not token:
            print(f"[push] monitor {name!r} (id={monitor_id}) has no pushToken yet",
                  flush=True)
            return
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-").lower()
        url_dir = pathlib.Path("/var/lib/homelab/monitoring/push-urls")
        url_dir.mkdir(parents=True, exist_ok=True)
        push_url = f"{kuma_url.rstrip('/')}/api/push/{token}"
        target = url_dir / f"{safe}.url"
        tmp = target.with_suffix(".url.tmp")
        tmp.write_text(push_url + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
        print(f"[push] wrote {target} for monitor {name!r}", flush=True)

    def sync_once() -> tuple:
        updated = {}
        updated_maint = {}
        with UptimeKumaApi(kuma_url, timeout=30) as api:
            api.login(username=kuma_user, password=kuma_pass)

            # ---------------------------------------------------------------
            # Notifications reconcile (#256). Declared entries become the
            # authoritative state — webhook URL, contentType, isDefault.
            # Existing notifications NOT in the declared list are left alone
            # (so a user can keep a manually-added backup Gotify route);
            # they just have isDefault demoted if a declared one claims it.
            # ---------------------------------------------------------------
            if desired_notifications_config:
                existing_notif = api.get_notifications() or []
                by_notif_name = {n.get("name"): n for n in existing_notif if n.get("name")}
                declared_names = {entry["name"] for entry in desired_notifications_config}
                wants_default = {
                    entry["name"] for entry in desired_notifications_config
                    if entry.get("isDefault")
                }

                # Demote any existing isDefault=True notification whose name is
                # NOT in our declared list. Lets a declared entry safely claim
                # default without two notifications firing for every monitor.
                if wants_default:
                    for n in existing_notif:
                        n_name = n.get("name")
                        if (
                            n.get("isDefault")
                            and n_name not in declared_names
                        ):
                            api.edit_notification(n["id"], isDefault=False)

                for entry in desired_notifications_config:
                    n_name = entry["name"]
                    n_type = entry.get("type", "webhook")
                    n_default = bool(entry.get("isDefault", False))
                    if n_type != "webhook":
                        raise UptimeKumaException(
                            f"notification {n_name!r}: only webhook type is supported"
                        )

                    payload = dict(
                        name=n_name,
                        type=n_type,
                        isDefault=n_default,
                        # applyExisting attaches the notification to ALL
                        # existing monitors when we (re)create with
                        # isDefault — without it, existing monitors keep
                        # whatever notification(s) they were already
                        # bound to and won't pick up this one until
                        # they're individually edited.
                        applyExisting=n_default,
                        webhookURL=entry["webhookURL"],
                        webhookContentType=entry.get("webhookContentType", "application/json"),
                    )

                    existing = by_notif_name.get(n_name)
                    if existing:
                        api.edit_notification(existing["id"], **payload)
                    else:
                        api.add_notification(**payload)

            # Re-fetch after the reconcile so the monitor loop uses the
            # latest default IDs.
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
                elif mon_type == "push":
                    kuma_type = MonitorType.PUSH
                else:
                    kuma_type = MonitorType.HTTP

                # Build kwargs common to add/edit. `type` MUST be in here so
                # edit_monitor() actually updates an existing monitor's type
                # when the desired type changes (e.g. http → json-query).
                # Previously type was only passed on the add path, so a monitor
                # created as "http" stayed "http" forever and the json-query
                # fields were silently orphaned.
                # Push monitors don't have URL/statuscodes/etc.; Kuma rejects them.
                if mon_type == "push":
                    common_kwargs = dict(
                        type=kuma_type,
                        name=name,
                        notificationIDList=notification_ids,
                        interval=interval,
                        maxretries=maxretries,
                        retryInterval=retry_interval,
                        resendInterval=resend_interval,
                    )
                else:
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

                # Push monitors have no URL — look up only by name.
                existing = by_name.get(name) if mon_type == "push" else (by_url.get(url) or by_name.get(name))
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
                        desired_notification_ids = sorted(notification_ids)
                    except TypeError:
                        desired_notification_ids = notification_ids
                    needs_update = (
                        str(existing.get("type") or "") != mon_type
                        or existing.get("name") != name
                        or existing.get("url") != url
                        or bool(existing.get("ignoreTls")) != ignore_tls
                        or (host_header and existing.get("headers") != headers_json)
                        or existing_codes != desired_codes
                        or existing_notifications != desired_notification_ids
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
                    cache_key = name if mon_type == "push" else url
                    updated[cache_key] = {"name": name, "url": url, "monitorId": monitor_id, "type": mon_type}
                    if mon_type == "push":
                        write_push_url(api, monitor_id, name, kuma_url)
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
                cache_key = name if mon_type == "push" else url
                updated[cache_key] = {"name": name, "url": url, "monitorId": monitor_id, "type": mon_type}
                if mon_type == "push":
                    write_push_url(api, monitor_id, name, kuma_url)

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
            default = "";
            description = ''
              URL to monitor. Required for http/json-query types.
              Push monitors don't have an outbound URL — they wait
              for inbound heartbeats — so set to "" or omit.
            '';
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
            type = lib.types.enum ["http" "json-query" "push"];
            default = "http";
            description = ''
              Monitor type: http, json-query, or push. Push monitors
              are created by `homelab.monitoring.deepProbes` — don't
              declare them directly here unless you know what you're
              doing.
            '';
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

    deepProbes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({config, ...}: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = ''
              Probe identifier — used as the Kuma monitor name, the
              systemd unit suffix, and the state-file basename. Must be
              unique across the fleet and stable: changing it orphans
              the previous Kuma push monitor.
            '';
            example = "Immich sync write-path";
          };
          command = lib.mkOption {
            type = lib.types.str;
            description = ''
              Absolute path to an executable that performs the probe.
              Exit 0 = healthy (oneshot then pushes to Kuma); any
              non-zero or timeout = unhealthy (no push, Kuma misses
              heartbeat and eventually marks DOWN). Stdout/stderr are
              journaled under the oneshot unit for forensics.
            '';
          };
          interval = lib.mkOption {
            type = lib.types.str;
            default = "5m";
            description = ''
              systemd OnUnitActiveSec value — how often the probe runs.
              The corresponding Kuma push monitor's `interval` is set
              to `intervalSecs` (see below) which should be ≥ this.
            '';
          };
          intervalSecs = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = ''
              Kuma push monitor's `interval` field (seconds). Kuma
              expects a heartbeat at most this often; if it goes
              `intervalSecs * (1 + maxretries) + retryInterval` seconds
              without one, the monitor goes DOWN. Match this to
              `interval` (default 5m = 300s).
            '';
          };
          timeout = lib.mkOption {
            type = lib.types.str;
            default = "60s";
            description = ''
              systemd TimeoutStartSec for the oneshot. If the probe
              command runs longer than this it is killed (SIGTERM →
              SIGKILL) and the run counts as a failure. Pick something
              short enough to surface hangs but long enough for a
              healthy probe with a degraded upstream — Immich's sync
              endpoint typically responds in <2s but can spike during
              heavy ingest.
            '';
          };
          maxretries = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = ''
              Kuma maxretries — consecutive missed heartbeats before
              the monitor flips DOWN and pages. Default 2 with
              intervalSecs=300 = ~15 min of continuous failure before
              alerting. Less forgiving than the HTTP monitor defaults
              because deep-probe failures indicate real write-path
              breaks, not transient blips.
            '';
          };
          retryInterval = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Kuma retryInterval — seconds between retries after a failed heartbeat.";
          };
          resendInterval = lib.mkOption {
            type = lib.types.int;
            default = 24;
            description = ''
              Kuma resendInterval — heartbeats between re-notifications
              while the monitor is still DOWN. At the default
              `intervalSecs = 300` (5 min) this is 2h; at intervalSecs=
              3600 (kopia freshness, 1h) it's 24h. Pick a number that
              gives the cadence you want.
              Operator preference recorded 2026-05-20: HTTP monitors
              stay at 4h (default below), push/deep probes re-page
              once a day.
            '';
          };
          serviceConfig = lib.mkOption {
            type = lib.types.attrs;
            default = {};
            description = ''
              Extra systemd serviceConfig for the probe oneshot.
              Common use: EnvironmentFile for API keys, LoadCredential
              for SOPS-managed secrets, RuntimeDirectory for state.
            '';
          };
        };
      }));
      default = [];
      description = ''
        Deep write-path probes. Each entry provisions:
          1. A Kuma push monitor (type=push) with the given name.
          2. A systemd timer + oneshot service named `deep-probe-<name>`.
          3. On healthy run, the oneshot curls the monitor's push URL
             (read from /var/lib/homelab/monitoring/push-urls/<name>.url
             which monitor_sync writes after creating the Kuma monitor).
        On non-zero exit OR timeout, no push happens and Kuma eventually
        marks DOWN after the configured maxretries.

        Use deepProbes for any stateful service whose HTTP healthcheck
        doesn't actually exercise the DB write path. See issue #252 and
        `.claude/rules/nixos-service-modules.md` Deep probes section.
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Notification name (unique key for reconciliation).";
          };
          type = lib.mkOption {
            type = lib.types.enum ["webhook"];
            default = "webhook";
            description = "Notification type. Only webhook is supported here.";
          };
          isDefault = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Attach this notification to every monitor automatically.
              Reconciler ensures only ONE notification has isDefault=true
              at a time — declaring a new one with isDefault=true demotes
              previous defaults to non-default. Other notifications stay
              available as manually-selectable for specific monitors.
            '';
          };
          webhookURL = lib.mkOption {
            type = lib.types.str;
            description = "Target URL for webhook notifications.";
          };
          webhookContentType = lib.mkOption {
            type = lib.types.enum ["application/json" "application/x-www-form-urlencoded"];
            default = "application/json";
            description = ''
              Content type Kuma uses for the webhook body. The
              alert-bridge expects JSON (#256).
            '';
          };
        };
      });
      default = [];
      description = ''
        Kuma notification entries reconciled declaratively by
        `homelab-monitoring-sync.service`. The default Kuma setup uses
        an in-UI Gotify webhook; declaring a notification here
        overrides/manages it as nix-as-source-of-truth. See #256 for
        the bridge-fronting design.
      '';
    };

    errorPatterns = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = ''
              Short alert title — becomes the Grafana alert name and the
              Gotify push title. Must be unique across the fleet.
            '';
            example = "Immich DB write failure";
          };
          unit = lib.mkOption {
            type = lib.types.str;
            description = ''
              systemd `unit` label to match in Loki. Usually exact
              (e.g. `immich-server.service`). For multi-unit services
              you can use a regex like `paperless-.+\\.service` — wrap
              it in `unit=~"..."` form by setting `unitIsRegex = true`.
            '';
          };
          unitIsRegex = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              If true, `unit` is treated as a regex (`unit=~"..."`).
              If false, exact match (`unit="..."`).
            '';
          };
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Optional host filter. Default null = any host. Mostly
              useful when you have the same service on multiple hosts
              and want to alert per-host.
            '';
          };
          container = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Optional `container` label filter (set by alloy from
              `_CONTAINER_NAME`). Useful for podman-driven services
              where the journal unit is generic (e.g. `podman-foo.service`)
              and we want to scope to a specific container name.
            '';
          };
          pattern = lib.mkOption {
            type = lib.types.str;
            description = ''
              LogQL regex (the part inside `|~ "..."`). Use `(?i)` for
              case-insensitive. Keep tight — broad patterns like
              `error` are noise. Target the SPECIFIC strings the
              service emits when actually broken. See #253 audit
              methodology.
            '';
            example = "PostgresError|permission denied for table|migration failed";
          };
          severity = lib.mkOption {
            type = lib.types.enum ["critical" "warning" "info"];
            default = "warning";
            description = ''
              Alert severity — critical maps to Gotify priority 8 in
              the alert-bridge. Use "critical" for service-unusable
              failures, "warning" for degraded states, "info" if you
              just want to know (rare; usually means the pattern
              shouldn't be an alert).
            '';
          };
          summary = lib.mkOption {
            type = lib.types.str;
            description = "One-line summary surfaced in the alert annotation + Gotify body.";
          };
          description = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = ''
              Optional longer description shown in Grafana and included
              in the claude context block. Use it to capture investigation
              tips: where to look, what the failure usually means.
            '';
          };
          window = lib.mkOption {
            type = lib.types.str;
            default = "5m";
            description = ''
              LogQL `count_over_time` window. Default 5m — match-within-5min
              is enough to debounce nearly anything, while staying short
              enough to page within ~6 min of the first failure (eval
              cadence is 1m).
            '';
          };
          threshold = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = ''
              count_over_time threshold to fire (count > threshold).
              Default 0 = ANY match within `window` pages. Bump for
              patterns where the service emits matching strings during
              normal startup/restart noise (e.g. Solr proxy 500s while
              replica peers reconnect — bump to 3 means "must see 4+
              errors in 5m before paging").
            '';
          };
        };
      });
      default = [];
      description = ''
        Per-service error log patterns. Each entry compiles into a
        Grafana Loki alert rule (see alerting.nix), fires on the first
        match within `window`, and routes through the alert-bridge for
        claude-summarised Gotify pushes.

        Quiet-by-construction: only patterns you opt into can alert.
        Don't catch generic "error" — see #253 audit methodology for
        the per-service fingerprint rationale and the rules-doc section
        for severity tiering.
      '';
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
      # Push-URL state dir: monitor_sync writes <safe-name>.url here
      # after creating each push monitor in Kuma; deep-probe oneshots
      # read those files at runtime. 0755 so non-root probe users can
      # read; the URLs are not secret (they're tokens specific to
      # individual monitors), but we keep the dir restricted-write.
      "d /var/lib/homelab/monitoring/push-urls 0755 root root -"
    ];

    systemd.services = {
      homelab-monitoring-sync = {
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
    } // (
    # Generate one (oneshot, timer) pair per deepProbe. The oneshot reads
    # the push URL from /var/lib/homelab/monitoring/push-urls/<slug>.url
    # (written by monitor_sync after the corresponding Kuma push monitor
    # is provisioned), runs the probe command, and on success curls the
    # push URL. On any failure (non-zero exit or timeout), no curl
    # happens; Kuma misses the heartbeat and eventually flips DOWN.
      lib.listToAttrs (map (probe: let
          slug = probeSlug probe.name;
          urlFile = "/var/lib/homelab/monitoring/push-urls/${slug}.url";
          probeRunner = pkgs.writeShellScript "deep-probe-${slug}-runner" ''
            set -uo pipefail

            url_file=${lib.escapeShellArg urlFile}

            # Run the probe; capture exit + duration for the push payload.
            t0=$(${pkgs.coreutils}/bin/date +%s%N)
            ${probe.command}
            rc=$?
            t1=$(${pkgs.coreutils}/bin/date +%s%N)
            ms=$(( (t1 - t0) / 1000000 ))

            if [ "$rc" -ne 0 ]; then
              echo "[deep-probe] ${probe.name}: command exited $rc — NOT pushing to Kuma" >&2
              exit "$rc"
            fi

            if [ ! -r "$url_file" ]; then
              echo "[deep-probe] ${probe.name}: push URL file missing: $url_file" >&2
              echo "[deep-probe]   (waiting for homelab-monitoring-sync to provision the Kuma monitor)" >&2
              exit 0   # don't fail the unit just because Kuma sync hasn't caught up yet
            fi

            push_url=$(${pkgs.coreutils}/bin/head -n1 "$url_file")
            ${pkgs.curl}/bin/curl -fsS --max-time 10 \
              --data-urlencode "status=up" \
              --data-urlencode "msg=OK rc=0" \
              --data-urlencode "ping=$ms" \
              -G "$push_url" >/dev/null
          '';
        in {
          name = "deep-probe-${slug}";
          value = {
            description = "Deep write-path probe: ${probe.name}";
            after = ["network-online.target" "homelab-monitoring-sync.service"];
            wants = ["network-online.target"];
            serviceConfig =
              {
                Type = "oneshot";
                ExecStart = probeRunner;
                TimeoutStartSec = probe.timeout;
              }
              // probe.serviceConfig;
          };
        })
        cfg.deepProbes));

    systemd.timers =
      lib.listToAttrs (map (probe: let
          slug = probeSlug probe.name;
        in {
          name = "deep-probe-${slug}";
          value = {
            description = "Deep write-path probe timer: ${probe.name}";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "2m";
              OnUnitActiveSec = probe.interval;
              # AccuracySec keeps the timer tightly on-schedule; the
              # alert latency math (intervalSecs * maxretries) assumes
              # we don't drift more than a few seconds.
              AccuracySec = "10s";
              Unit = "deep-probe-${slug}.service";
            };
          };
        })
        cfg.deepProbes);
  };
}
