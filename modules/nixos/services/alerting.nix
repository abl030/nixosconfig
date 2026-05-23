# Grafana-driven alerting → Gotify push notifications.
#
# Lives on the host that runs the LGTM stack (Grafana is the alerting engine,
# Mimir is the datasource). Provisions:
#   - "Gotify" webhook contact point (token injected at startup, never in store)
#   - Alert rules (e.g. unexpected host reboot via node_boot_time_seconds)
#   - Notification policy routing all alerts to Gotify
#
# Issue: #201 — alert on unexpected Proxmox host reboot.
# See docs/wiki/services/lgtm-stack.md "Alerting" section for the manual
# Gotify app/token setup and Grafana → Gotify body-format gotcha.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.alerting;

  # Contact-point YAML template. The Gotify token is a placeholder filled at
  # startup by the prestart unit so it never lands in the Nix store.
  #
  # Why this works: Gotify's POST /message endpoint accepts JSON bodies and
  # picks up the top-level `title` and `message` fields, ignoring everything
  # else. Grafana's default webhook payload happens to put both fields at the
  # top level, so no body-template override is needed — the payload's extra
  # alertmanager-style metadata is silently discarded by Gotify.
  # When alertBridge is enabled, Grafana posts to the bridge instead of
  # straight to Gotify — the bridge re-queries Loki for matching lines,
  # pipes context to claude -p, and forwards a summary to Gotify itself.
  # The URL has no `?token=` because the bridge holds the token.
  # See docs/wiki/services/lgtm-stack.md "alert-bridge" section.
  bridgeEnabled = config.homelab.services.alertBridge.enable or false;
  bridgePort = config.homelab.services.alertBridge.listenPort or 9876;
  webhookUrl =
    if bridgeEnabled
    then "http://127.0.0.1:${toString bridgePort}/alert"
    else "${cfg.gotifyUrl}/message?token=__GOTIFY_TOKEN__";

  contactPointsTemplate = pkgs.writeText "grafana-contact-points.yaml" ''
    apiVersion: 1
    contactPoints:
      - orgId: 1
        name: Gotify
        receivers:
          - uid: gotify-default
            type: webhook
            disableResolveMessage: false
            settings:
              url: ${webhookUrl}
              httpMethod: POST
              maxAlerts: 0
  '';

  # Alert rule DAG: query → reduce → threshold. Grafana 10+ requires this
  # explicit shape (vs Prometheus' single-PromQL alert form). Each step has a
  # refId; the rule's `condition` names the final boolean refId.
  rebootAlerts = lib.optionals cfg.rebootAlert.enable (map (instance: {
      uid = "homelab-reboot-${instance}";
      title = "${instance} unexpected reboot";
      condition = "C";
      # Fire after a single positive evaluation. Reboot-detection is binary —
      # there's no flapping to suppress, and `for: 0s` minimises notification
      # latency. The alert auto-resolves once uptime crosses the threshold.
      "for" = "0s";
      # When Mimir is briefly unreachable (network blip, server restart),
      # treat that as "no event" rather than firing a spurious alert. The host
      # reboot signal is what we care about, not query-pipeline health.
      noDataState = "OK";
      execErrState = "OK";
      data = [
        {
          refId = "A";
          queryType = "";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          # UID matches the pinned datasource in loki-server.nix.
          datasourceUid = "Prometheus";
          model = {
            refId = "A";
            # Uptime in seconds. Filtered to this instance only — the alert
            # rule itself is per-instance so we never need to demux by label.
            expr = ''time() - node_boot_time_seconds{instance="${instance}"}'';
            instant = true;
            intervalMs = 60000;
            maxDataPoints = 43200;
            datasource = {
              type = "prometheus";
              uid = "Prometheus";
            };
          };
        }
        {
          refId = "B";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "B";
            type = "reduce";
            expression = "A";
            reducer = "last";
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
        {
          refId = "C";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "C";
            type = "threshold";
            expression = "B";
            conditions = [
              {
                evaluator = {
                  params = [cfg.rebootAlert.uptimeThresholdSeconds];
                  type = "lt";
                };
                operator.type = "and";
                query.params = ["C"];
                reducer = {
                  params = [];
                  type = "last";
                };
                type = "query";
              }
            ];
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
      ];
      annotations = {
        summary = "${instance} rebooted recently";
        description = ''
          Host ${instance} has uptime < ${toString cfg.rebootAlert.uptimeThresholdSeconds}s.
          If this is outside a planned maintenance window, investigate (power
          transient, kernel panic, OOM, hardware fault). The 2026-02-22 prom
          crash that motivated this alert (#201) is the canonical example.
        '';
      };
      labels = {
        severity = "warning";
        host = instance;
      };
    })
    cfg.rebootAlert.instances);

  # Helper: build a Loki-backed alert rule with the same A/B/C DAG shape
  # as the Prometheus reboot rule above.
  #   uid, title, summary, description, severity — alert identity + body
  #   logql — the LogQL expression (must produce numeric series via
  #     count_over_time/sum/etc.) that is > 0 when the alert should fire
  mkLokiAlert = {
    uid,
    title,
    summary,
    description,
    severity,
    logql,
    # Raw stream-selector form of the query, no aggregation wrapper.
    # Used by alert-bridge to fetch actual matching log lines rather
    # than scalar counts.
    lokiLines ? null,
    # count_over_time threshold to fire. Default 0 = ANY match in the
    # window pages. Bump for noisy patterns where the underlying
    # service emits the matching string during startup/restart cascades
    # — e.g. Solr proxy 500s while replica peers reconnect. A bigger
    # number turns the alert into "sustained failure" not "any blip".
    threshold ? 0,
  }: {
    inherit uid title;
    condition = "C";
    # `for: 0s`: fire on first positive evaluation. The query already uses
    # a 5m count_over_time window so flapping is absorbed inside the query.
    "for" = "0s";
    # Loki transient unreachability shouldn't page; treat as no event.
    noDataState = "OK";
    execErrState = "OK";
    data = [
      {
        refId = "A";
        queryType = "range";
        relativeTimeRange = {
          from = 600;
          to = 0;
        };
        datasourceUid = cfg.dbAuditAlert.lokiDatasourceUid;
        model = {
          refId = "A";
          # Loki range query — Grafana wraps the expr in its own time-window
          # handling. The count_over_time window inside is what controls
          # the lookback for matches.
          expr = logql;
          queryType = "range";
          intervalMs = 60000;
          maxDataPoints = 43200;
          datasource = {
            type = "loki";
            uid = cfg.dbAuditAlert.lokiDatasourceUid;
          };
        };
      }
      {
        refId = "B";
        queryType = "";
        relativeTimeRange = {
          from = 0;
          to = 0;
        };
        datasourceUid = "__expr__";
        model = {
          refId = "B";
          type = "reduce";
          expression = "A";
          reducer = "last";
          datasource = {
            type = "__expr__";
            uid = "__expr__";
          };
        };
      }
      {
        refId = "C";
        queryType = "";
        relativeTimeRange = {
          from = 0;
          to = 0;
        };
        datasourceUid = "__expr__";
        model = {
          refId = "C";
          type = "threshold";
          expression = "B";
          conditions = [
            {
              evaluator = {
                params = [threshold];
                type = "gt";
              };
              operator.type = "and";
              query.params = ["C"];
              reducer = {
                params = [];
                type = "last";
              };
              type = "query";
            }
          ];
          datasource = {
            type = "__expr__";
            uid = "__expr__";
          };
        };
      }
    ];
    annotations = {
      inherit summary description;
    };
    # `loki_lines` is read by alert-bridge (services/alert-bridge.nix).
    # The bridge runs THIS raw stream-selector query (not the aggregated
    # `logql` used for the alert condition) to fetch actual matching log
    # lines, then pipes them through claude -p for a summary before
    # forwarding to Gotify. `loki_query` is the aggregated form, kept
    # for reference in the alert payload; Prometheus-based rules set
    # neither and the bridge handles them with metadata only.
    labels =
      {
        inherit severity;
        loki_query = logql;
      }
      // (lib.optionalAttrs (lokiLines != null) {loki_lines = lokiLines;});
  };

  dbAuditAlerts = lib.optionals cfg.dbAuditAlert.enable [
    (mkLokiAlert {
      uid = "homelab-pg-superuser-ddl";
      title = "Unexpected postgres-superuser DDL in *-db container";
      severity = "warning";
      summary = "postgres-role DDL outside mk-pg-container startup";
      description = ''
        A nspawn *-db container's journal logged a CREATE/ALTER/DROP/etc.
        statement issued as the `postgres` superuser, NOT tagged with
        application_name=mk-pg-container-startup. This is the signature
        of either a legitimate operator shell session (machinectl shell
        + psql) OR drift like the asset_edit_audit incident (#250). Worth
        a glance either way — the journal entry has user, db, pid, client.

        Query in Grafana Explore (Loki):
          {host=~".+", unit=~"container@.+-db\\.service"}
            |~ "postgres@[^ ]+ from .+ LOG: +statement: (?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)"
            !~ "mk-pg-container-startup"
      '';
      # `LOG:  statement:` is what postgres emits when log_statement=ddl
      # is on. log_line_prefix gives us the `<user>@<db>/<app> from <host>:`
      # block we filter on. We exclude our own setup tag so boot-time
      # extension SQL doesn't fire.
      logql = ''sum(count_over_time({host=~".+", unit=~"container@.+-db\\.service"} |~ "postgres@[^ ]+ from .+ LOG: +statement: (?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)" !~ "mk-pg-container-startup" [5m]))'';
      lokiLines = ''{host=~".+", unit=~"container@.+-db\\.service"} |~ "postgres@[^ ]+ from .+ LOG: +statement: (?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)" !~ "mk-pg-container-startup"'';
    })
    (mkLokiAlert {
      uid = "homelab-mariadb-audit-ddl";
      title = "MariaDB audit: DDL from non-excluded user";
      severity = "warning";
      summary = "mariadb DDL via TCP — server_audit caught it";
      description = ''
        A nspawn *-db container running MariaDB logged a server_audit
        QUERY_DDL event from a user not in server_audit_excl_users
        (i.e. not local root/mysql). That means external TCP DDL, which
        we don't expect under normal app traffic. Investigate the
        session — server_audit's syslog line includes user, host, query.

        Query in Grafana Explore (Loki):
          {host=~".+", unit=~"container@.+-db\\.service"}
            |~ ",QUERY,.*,'(?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE) "
      '';
      logql = ''sum(count_over_time({host=~".+", unit=~"container@.+-db\\.service"} |~ ",QUERY,.*,'(?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE) " [5m]))'';
      lokiLines = ''{host=~".+", unit=~"container@.+-db\\.service"} |~ ",QUERY,.*,'(?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE) "'';
    })
  ];

  # Per-service errorPatterns from `homelab.monitoring.errorPatterns`.
  # Each entry becomes a Loki alert rule with both `loki_query` (aggregated
  # count, used as the alert condition) and `loki_lines` (raw stream
  # selector, used by the alert-bridge to fetch actual log lines for
  # claude). See #253 and the rules-doc "Per-service errorPatterns"
  # section for the per-service audit methodology.
  # Grafana enforces a hard 40-char limit on alert rule UIDs. Our prefix
  # "homelab-err-" is 12, so the slug part must be ≤28. To stay
  # deterministic and collision-free across long pattern names, derive
  # the slug from a sha256 of the name: first 16 hex chars. Trade-off:
  # less readable in the Grafana UI (slug is opaque), but the rule
  # `title` (= ep.name) is the human-friendly field everywhere else.
  errorPatternSlug = name: builtins.substring 0 16 (builtins.hashString "sha256" name);

  # Compose the LogQL stream selector for an errorPattern entry.
  # Note: `unit` regexes also need logqlEscape applied — same backslash
  # double-escape requirement as patterns.
  errorPatternSelector = ep: let
    hostPart =
      if ep.host == null
      then ''host=~".+"''
      else ''host="${ep.host}"'';
    unitPart =
      if ep.unitIsRegex
      then ''unit=~"${logqlEscape ep.unit}"''
      else ''unit="${ep.unit}"'';
    containerPart =
      pkgs.lib.optionalString (ep.container != null)
      '', container="${ep.container}"'';
  in "{${hostPart}, ${unitPart}${containerPart}}";

  # LogQL string literals require backslashes to be doubled (`\\`) — the
  # parser otherwise rejects regex metacharacters like `\d`, `\.`, `\[`
  # with "invalid char escape" before the regex engine ever sees them.
  # Double quotes must also be backslash-escaped, otherwise a pattern
  # containing a literal `"` (e.g. `user "paperless"`) terminates the
  # LogQL string mid-regex and the rule fails to evaluate.
  # Users write patterns the way they'd type them in Grafana Explore
  # (`\d+`, `\.`, `"foo"`); we escape here at framework level so the
  # final LogQL query string is well-formed.
  logqlEscape = s: builtins.replaceStrings ["\\" "\""] ["\\\\" "\\\""] s;

  errorPatternAlerts = map (ep: let
    slug = errorPatternSlug ep.name;
    selector = errorPatternSelector ep;
    pattern = logqlEscape ep.pattern;
    desc =
      (
        if ep.description == ""
        then ""
        else ep.description + "\n\n"
      )
      + ''
        Query in Grafana Explore (Loki):
          ${selector} |~ "${pattern}"
      '';
  in
    mkLokiAlert {
      uid = "homelab-err-${slug}";
      title = ep.name;
      inherit (ep) severity;
      inherit (ep) summary;
      description = desc;
      logql = ''sum(count_over_time(${selector} |~ "${pattern}" [${ep.window}]))'';
      lokiLines = ''${selector} |~ "${pattern}"'';
      inherit (ep) threshold;
    })
  config.homelab.monitoring.errorPatterns;

  # Fleet-wide OOM alert. Reuses mkLokiAlert so the alert-bridge can
  # fetch the actual oom-kill log line and feed it to claude for a useful
  # Gotify body ("oom-killed: postgres pid 12345 ..." instead of just a
  # count).
  #
  # CRITICAL: scope to transport="kernel" — alloy promotes the journald
  # _TRANSPORT field to a stream label, so `transport="kernel"` matches
  # only the actual kernel ring buffer (which is where oom_kill emits).
  # An earlier version of this rule used just `{source="journald"}` and
  # immediately self-triggered: Grafana's scheduler logs the alert query
  # string to journald, alloy ships it back to Loki, next eval matches
  # the regex inside the logged query. transport="kernel" cuts off the
  # feedback loop because no userland app logs under that transport.
  #
  # Tower (Unraid) ships via syslog, not journald — its OOMs would slip
  # past this rule. Acceptable for now; document when/if it bites.
  oomAlerts = lib.optionals cfg.oomAlert.enable [
    (mkLokiAlert {
      uid = "homelab-oom-fleet";
      title = "Kernel OOM killer fired";
      severity = "warning";
      summary = "OOM kill detected in kernel log — see line for the victim";
      description = ''
        The Linux OOM killer ran on a fleet host within the last 5 minutes.
        Check the matched log line (delivered via alert-bridge) for the
        process that died, or query Grafana Explore:
          {source="journald", transport="kernel"} |~ "(?i)(out of memory|oom[-_](kill|reaper)|memory cgroup out of memory)"
      '';
      # Regex covers:
      #   - "Out of memory: Killed process ..." (classic kernel oom_kill)
      #   - "oom-kill:" / "oom_reaper:" (newer kernels)
      #   - "Memory cgroup out of memory" (cgroup OOM)
      logql = ''sum(count_over_time({source="journald", transport="kernel"} |~ "(?i)(out of memory|oom[-_](kill|reaper)|memory cgroup out of memory)" [5m]))'';
      lokiLines = ''{source="journald", transport="kernel"} |~ "(?i)(out of memory|oom[-_](kill|reaper)|memory cgroup out of memory)"'';
    })
  ];

  # Per-host log-ingestion silence alert. Fires when a fleet host that
  # should always be shipping logs to Loki has sent zero lines in the
  # past `window`. Closes the silent-log-loss gap that hid prom's
  # broken alloy for weeks (2026-05-24 stale-TCP-connection trap —
  # see docs/wiki/services/lgtm-stack.md "Alloy holds stale TCP
  # connections across vhost migrations").
  #
  # CRITICAL settings vs the rest of the alert family:
  #   - noDataState = Alerting: if the host has been silent long
  #     enough that even its `host` label has aged out of Loki's
  #     cache, the query returns no data — we still want that to fire.
  #   - threshold "lt": fires when count < 1 (i.e. 0 log lines).
  #     The default mkLokiAlert uses "gt" which is the opposite shape.
  ingestionSilenceAlerts = lib.optionals cfg.ingestionSilenceAlert.enable (
    lib.mapAttrsToList (host: hostCfg: let
      window =
        if hostCfg.window != null
        then hostCfg.window
        else cfg.ingestionSilenceAlert.defaultWindow;
      forDuration =
        if hostCfg.forDuration != null
        then hostCfg.forDuration
        else cfg.ingestionSilenceAlert.defaultForDuration;
    in {
      uid = "homelab-loki-silent-${host}";
      title = "${host} stopped shipping logs to Loki";
      condition = "C";
      "for" = forDuration;
      noDataState = "Alerting";
      execErrState = "OK";
      data = [
        {
          refId = "A";
          queryType = "range";
          relativeTimeRange = {
            from = 900;
            to = 0;
          };
          datasourceUid = cfg.dbAuditAlert.lokiDatasourceUid;
          model = {
            refId = "A";
            expr = ''sum(count_over_time({host="${host}"}[${window}]))'';
            queryType = "range";
            intervalMs = 60000;
            maxDataPoints = 43200;
            datasource = {
              type = "loki";
              uid = cfg.dbAuditAlert.lokiDatasourceUid;
            };
          };
        }
        {
          refId = "B";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "B";
            type = "reduce";
            expression = "A";
            reducer = "last";
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
        {
          refId = "C";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "C";
            type = "threshold";
            expression = "B";
            conditions = [
              {
                evaluator = {
                  params = [1];
                  type = "lt";
                };
                operator.type = "and";
                query.params = ["C"];
                reducer = {
                  params = [];
                  type = "last";
                };
                type = "query";
              }
            ];
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
      ];
      annotations = {
        summary = "Loki received 0 log lines from ${host} in the last ${window}.";
        description = ''
          Either ${host} is genuinely offline OR its log shipper has
          stopped sending. Common causes:

          - alloy holding a stale TCP connection to a migrated vhost
            (2026-05-24 incident on prom). Fix: `ssh ${host}
            systemctl restart alloy`.
          - alloy config error after a NixOS rebuild. Check:
            `ssh ${host} journalctl -u alloy -n 50`.
          - Host actually down. Check Tailscale + the relevant
            hypervisor (prom for VMs, tower for VMs on tower).
          - For tower/pfsense: syslog forwarder broken. Check syslog
            config on the box.

          See docs/wiki/services/lgtm-stack.md "Alloy holds stale TCP
          connections across vhost migrations" for the 2026-05-24
          incident that motivated this alert.
        '';
      };
      labels = {
        severity = "warning";
        category = "ingestion";
        host = host;
      };
    })
    cfg.ingestionSilenceAlert.hosts
  );

  # Fleet-wide disk-pressure alert. Prometheus rule — the alerting query
  # returns one series per host/mountpoint/fstype, so the alert fires
  # independently per filesystem and the labels carry through to the
  # Gotify body. Excludes ephemeral and pseudo filesystems where
  # "fullness" is either expected or meaningless.
  diskAlerts = lib.optionals cfg.diskPressureAlert.enable [
    {
      uid = "homelab-disk-pressure-fleet";
      title = "Filesystem ≥ ${toString cfg.diskPressureAlert.thresholdPercent}% full";
      condition = "C";
      "for" = cfg.diskPressureAlert.forDuration;
      noDataState = "OK";
      execErrState = "OK";
      data = [
        {
          refId = "A";
          queryType = "";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          datasourceUid = "Prometheus";
          model = {
            refId = "A";
            datasource = {
              type = "prometheus";
              uid = "Prometheus";
            };
            # Percent used per filesystem. Using avail rather than (size -
            # free) because ext4/xfs reserve ~5% for root and avail
            # accounts for that — matches what `df` shows.
            expr = ''
              100 * (1 - (
                node_filesystem_avail_bytes{
                  fstype!~"${cfg.diskPressureAlert.fstypeExcludeRegex}",
                  mountpoint!~"${cfg.diskPressureAlert.mountpointExcludeRegex}"
                }
                /
                node_filesystem_size_bytes{
                  fstype!~"${cfg.diskPressureAlert.fstypeExcludeRegex}",
                  mountpoint!~"${cfg.diskPressureAlert.mountpointExcludeRegex}"
                }
              ))
            '';
            instant = true;
            intervalMs = 60000;
            maxDataPoints = 43200;
          };
        }
        {
          refId = "B";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "B";
            type = "reduce";
            expression = "A";
            reducer = "last";
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
        {
          refId = "C";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            refId = "C";
            type = "threshold";
            expression = "B";
            conditions = [
              {
                evaluator = {
                  params = [cfg.diskPressureAlert.thresholdPercent];
                  type = "gt";
                };
                operator.type = "and";
                query.params = ["C"];
                reducer = {
                  params = [];
                  type = "last";
                };
                type = "query";
              }
            ];
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
      ];
      annotations = {
        summary = "{{ $labels.host }} {{ $labels.mountpoint }} ≥ ${toString cfg.diskPressureAlert.thresholdPercent}% full";
        description = ''
          Filesystem {{ $labels.mountpoint }} on host {{ $labels.host }}
          ({{ $labels.fstype }}) crossed ${toString cfg.diskPressureAlert.thresholdPercent}%
          usage and stayed there for ${cfg.diskPressureAlert.forDuration}.
          Free space, prune snapshots, or grow the volume — at our nightly
          ingest rates a filesystem hitting 100% will block kopia backups
          and likely take services offline.
        '';
      };
      labels = {
        severity = "warning";
        category = "disk";
      };
    }
  ];

  rules = {
    apiVersion = 1;
    groups =
      lib.optionals (rebootAlerts != []) [
        {
          orgId = 1;
          name = "host-health";
          folder = "Homelab";
          # 1m matches the alloy scrape interval; finer eval is wasted work.
          interval = "1m";
          rules = rebootAlerts;
        }
      ]
      ++ lib.optionals (dbAuditAlerts != []) [
        {
          orgId = 1;
          name = "db-audit";
          folder = "Homelab";
          interval = "1m";
          rules = dbAuditAlerts;
        }
      ]
      ++ lib.optionals (errorPatternAlerts != []) [
        {
          orgId = 1;
          name = "service-errors";
          folder = "Homelab";
          interval = "1m";
          rules = errorPatternAlerts;
        }
      ]
      ++ lib.optionals (oomAlerts != []) [
        {
          orgId = 1;
          name = "memory-pressure";
          folder = "Homelab";
          interval = "1m";
          rules = oomAlerts;
        }
      ]
      ++ lib.optionals (diskAlerts != []) [
        {
          orgId = 1;
          name = "disk-pressure";
          folder = "Homelab";
          interval = "1m";
          rules = diskAlerts;
        }
      ]
      ++ lib.optionals (ingestionSilenceAlerts != []) [
        {
          orgId = 1;
          name = "log-ingestion-silence";
          folder = "Homelab";
          interval = "1m";
          rules = ingestionSilenceAlerts;
        }
      ];
  };

  policies = {
    apiVersion = 1;
    policies = [
      {
        orgId = 1;
        receiver = "Gotify";
        # Group by alertname so multiple per-host reboot alerts (if we ever
        # alarm a fleet of hosts at once after a power blip) collapse into
        # one notification per alert family.
        group_by = ["alertname"];
        group_wait = "30s";
        group_interval = "5m";
        # 12h re-page if still firing — a permanently-firing alert without
        # auto-resolve would otherwise stay silent after the first page.
        # 24h re-page cadence (2026-05-20 operator preference). Lower
        # than this gets spammy on long-lived alerts (e.g. a deepProbe
        # red because a downstream service is being repaired); higher
        # risks forgetting the alert exists.
        repeat_interval = "24h";
      }
    ];
  };
in {
  options.homelab.services.alerting = {
    enable = lib.mkEnableOption "Grafana alerting → Gotify push notifications";

    gotifyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://gotify.ablz.au";
      description = "Base URL of the Gotify server (no trailing slash).";
    };

    gotifyTokenSopsFile = lib.mkOption {
      type = lib.types.path;
      default = config.homelab.secrets.sopsFile "gotify.env";
      description = ''
        Sops file containing GOTIFY_TOKEN. Reuses the existing agent-ping
        token by default — operationally that means agent pings and Grafana
        alerts share one Gotify "application" stream. Split into a dedicated
        token if/when you want independently-revocable credentials.
      '';
    };

    dbAuditAlert = {
      enable =
        lib.mkEnableOption "Alert on unexpected DB DDL (mk-pg-container superuser, mk-mariadb non-excluded user)"
        // {default = true;};

      lokiDatasourceUid = lib.mkOption {
        type = lib.types.str;
        default = "P8E80F9AEF21F6940";
        description = ''
          UID of the Loki datasource in Grafana, used by the DDL audit
          alert rules. See docs/wiki/services/lgtm-stack.md "Loki
          datasource UID auto-generation gotcha" for full context and
          the lookup command if this needs to change.
        '';
      };
    };

    rebootAlert = {
      enable = lib.mkEnableOption "Alert when monitored hosts reboot unexpectedly" // {default = true;};

      instances = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["prom"];
        description = ''
          List of `instance` label values from node_exporter to alert on.
          One alert rule is generated per instance. Prom is the canonical
          target — the 2026-02-22 hard crash is what motivated #201.
        '';
        example = ["prom" "doc1"];
      };

      uptimeThresholdSeconds = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = ''
          Fire when (time() - node_boot_time_seconds) is below this many
          seconds. 600s = 10 minutes — long enough to survive a missed
          eval after boot, short enough that the alert doesn't linger.
        '';
      };
    };

    oomAlert = {
      enable = lib.mkEnableOption "Alert when the kernel OOM killer fires on any fleet host" // {default = true;};
    };

    ingestionSilenceAlert = {
      enable = lib.mkEnableOption "Alert when a monitored fleet host stops shipping logs to Loki" // {default = true;};

      defaultWindow = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = ''
          Default LogQL `count_over_time` lookback window when a host
          entry doesn't override `window`. 15m absorbs nightly
          maintenance reboots (typically 5-10 min) without firing
          while still catching real silent-failure inside one cycle.
        '';
      };

      defaultForDuration = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = ''
          Default for-duration when a host entry doesn't override
          `forDuration`. 5m + the 15m default window = ~20 min
          minimum time-to-fire.
        '';
      };

      hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            window = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Override the default count_over_time window for this host.";
            };
            forDuration = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Override the default for-duration for this host.";
            };
          };
        });
        # Tier 1 (critical infra: firewall, hypervisor, NAS) — 5min
        # window + 1min for = ~6min time-to-fire. These boxes don't
        # do nightly reboots, so the maintenance-window safety margin
        # other hosts need doesn't apply. Silence on these = real loss.
        #
        # Tier 2 (defaults: 15m window + 5m for = ~20min time-to-fire)
        # for VMs that DO have nightly auto-reboots.
        default = {
          # Tier 1: critical, page fast.
          tower = {
            window = "5m";
            forDuration = "1m";
          };
          prom = {
            window = "5m";
            forDuration = "1m";
          };
          pfsense = {
            window = "5m";
            forDuration = "1m";
          };
          # Tier 2: services that auto-reboot overnight (use defaults).
          doc2 = {};
          proxmox-vm = {};
          igpu = {};
          wsl = {};
        };
        description = ''
          `host` label values that should always be sending logs.
          Each key generates one alert rule; values can override
          `window` and/or `forDuration` independently of the fleet
          defaults. An empty `{}` uses both defaults.

          Excludes legitimately-offline hosts:
          - framework, epimetheus (workstations that sleep)
          - dev (development VM, off most of the time)
          - caddy, cache (Home Manager-only; no alloy/journald to ship)

          Background: alloy can silently drop every batch with HTTP 421
          if it holds a stale TCP connection to a migrated vhost IP.
          This happened to prom from the LGTM migration through
          2026-05-24 — nobody noticed because alloy itself reported
          healthy. The per-host silence alert closes that gap. See
          docs/wiki/services/lgtm-stack.md "Alloy holds stale TCP
          connections across vhost migrations".
        '';
        example = lib.literalExpression ''
          {
            tower = { window = "5m"; forDuration = "1m"; };
            doc2 = {};  # use defaults
          }
        '';
      };
    };

    diskPressureAlert = {
      enable = lib.mkEnableOption "Alert when any filesystem crosses a usage threshold" // {default = true;};

      thresholdPercent = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = ''
          Fire when filesystem usage (1 - avail/size) exceeds this many
          percent. 90% leaves enough headroom for typical churn while
          still giving us time to act before a disk fills.
        '';
      };

      forDuration = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = ''
          How long the threshold must be exceeded before firing. 15m rides
          through nightly backup spikes and large transient writes; shorter
          values pager-bomb during kopia/borg snapshot churn.
        '';
      };

      fstypeExcludeRegex = lib.mkOption {
        type = lib.types.str;
        # Escape depth: this string is emitted into a PromQL string literal,
        # which uses Go-style escapes. `\.` is "unknown escape" — to land a
        # literal backslash inside the PromQL string we need `\\`, which
        # requires `\\\\` in Nix source. The regex engine then reads `\\.`
        # → literal `.`. Same chain as the ntopng dashboard escapes in
        # loki-server.nix vpnClientIPRegex.
        default = "tmpfs|devtmpfs|overlay|squashfs|fuse\\\\..*|nsfs|tracefs|debugfs|cgroup.*|proc|sysfs|configfs|autofs|mqueue|pstore|bpf|securityfs|ramfs|hugetlbfs";
        description = ''
          fstype label values to exclude from the disk-pressure query.
          Strips ephemeral/pseudo filesystems where "fullness" is either
          expected or meaningless.
        '';
      };

      mountpointExcludeRegex = lib.mkOption {
        type = lib.types.str;
        default = "/nix/store|/run(/.*)?|/proc(/.*)?|/sys(/.*)?|/dev(/.*)?|/snap(/.*)?|/var/lib/docker/.*|/var/lib/containers/.*|/var/lib/nspawn/.*|/var/lib/machines/.*";
        description = ''
          mountpoint label values to exclude from the disk-pressure query.
          Strips read-only Nix store views, ephemeral /run, and container/
          nspawn-internal overlays whose backing filesystem is alerted on
          via its real mountpoint.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.services.loki.enable or false;
        message = ''
          homelab.services.alerting requires homelab.services.loki to be
          enabled on the same host — Grafana lives in the LGTM stack module
          and is the alerting engine.
        '';
      }
    ];

    # Grafana reads provisioning files at startup. The contact-point YAML
    # is rendered into this directory by the prestart unit below, with the
    # Gotify token sed-substituted in (so the secret never hits the store).
    systemd = {
      tmpfiles.rules = [
        "d /var/lib/grafana-alerting 0750 grafana grafana - -"
      ];

      services = {
        grafana-alerting-prestart = {
          description = "Render Grafana contact-points YAML with Gotify token";
          wantedBy = ["multi-user.target"];
          # Order after sops so /run/secrets/gotify-alerting/token exists.
          # We read /run/secrets directly (not via EnvironmentFile=), so
          # sops-nix can't infer the ordering for us.
          after = ["sops-install-secrets.service"];
          wants = ["sops-install-secrets.service"];
          before = ["grafana.service"];
          requiredBy = ["grafana.service"];
          path = with pkgs; [coreutils gnused];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "grafana";
            Group = "grafana";
          };
          script = ''
            set -euo pipefail
            token_file="/run/secrets/gotify-alerting/token"
            if [[ ! -r "$token_file" ]]; then
              echo "grafana-alerting: token file not readable: $token_file" >&2
              exit 1
            fi
            raw=$(cat "$token_file")
            token="''${raw#GOTIFY_TOKEN=}"
            token=$(printf '%s' "$token" | tr -d '\r\n')
            if [[ -z "$token" ]]; then
              echo "grafana-alerting: empty token after strip" >&2
              exit 1
            fi
            out="/var/lib/grafana-alerting/contactPoints.yaml"
            sed "s|__GOTIFY_TOKEN__|$token|" \
              ${contactPointsTemplate} > "$out"
            chmod 0640 "$out"
          '';
        };

        # Force grafana to restart whenever our prestart unit's derivation
        # changes (e.g. URL change, token-extraction logic change). Without
        # this, switch-to-configuration would update the prestart unit but
        # leave grafana running with the old contact-points file in memory.
        # See docs/wiki/nixos-service-modules.md "restartTriggers" for the
        # general pattern (originally for nspawn DB containers; same lesson
        # applies to any prestart-materialized config).
        grafana = {
          restartTriggers = [
            config.systemd.units."grafana-alerting-prestart.service".unit
          ];
        };
      };
    };

    sops.secrets."gotify-alerting/token" = {
      sopsFile = cfg.gotifyTokenSopsFile;
      format = "dotenv";
      key = "GOTIFY_TOKEN";
      owner = "grafana";
      mode = "0400";
    };

    services.grafana.provision.alerting = {
      contactPoints.path = "/var/lib/grafana-alerting/contactPoints.yaml";
      rules.settings = rules;
      policies.settings = policies;
    };
  };
}
