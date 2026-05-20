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
                params = [0];
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
  errorPatternSlug = name:
    pkgs.lib.toLower (
      pkgs.lib.concatStrings (
        pkgs.lib.filter (c: builtins.match "[a-z0-9-]" c != null) (
          pkgs.lib.stringToCharacters (
            builtins.replaceStrings
            ["/" " " "(" ")" "—" "[" "]" "." "_" ":"]
            ["-" "-" "" "" "-" "" "" "-" "-" "-"]
            (pkgs.lib.toLower name)
          )
        )
      )
    );

  # Compose the LogQL stream selector for an errorPattern entry.
  errorPatternSelector = ep: let
    hostPart =
      if ep.host == null
      then ''host=~".+"''
      else ''host="${ep.host}"'';
    unitPart =
      if ep.unitIsRegex
      then ''unit=~"${ep.unit}"''
      else ''unit="${ep.unit}"'';
    containerPart =
      pkgs.lib.optionalString (ep.container != null)
      '', container="${ep.container}"'';
  in "{${hostPart}, ${unitPart}${containerPart}}";

  errorPatternAlerts =
    map (ep: let
      slug = errorPatternSlug ep.name;
      selector = errorPatternSelector ep;
      pattern = ep.pattern;
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
        severity = ep.severity;
        summary = ep.summary;
        description = desc;
        logql = ''sum(count_over_time(${selector} |~ "${pattern}" [${ep.window}]))'';
        lokiLines = ''${selector} |~ "${pattern}"'';
      })
    config.homelab.monitoring.errorPatterns;

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
        repeat_interval = "12h";
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
        # See .claude/rules/nixos-service-modules.md "restartTriggers" for the
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
