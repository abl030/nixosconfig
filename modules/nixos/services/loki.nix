# Alloy shipper + optional syslog receiver on every NixOS host.
# Ships journald + node_exporter + process-exporter to the LGTM stack via HTTPS FQDN.
# See docs/wiki/services/lgtm-stack.md for the server side + DNS-first rule.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.loki;

  # Ship via HTTPS to the service FQDN (Cloudflare A records are synced by
  # homelab.localProxy on whichever host runs homelab.services.loki — moving
  # the server is a one-deploy change, no grep-and-replace). If THIS host
  # runs the server, short-circuit to localhost to skip the nginx round-trip.
  selfHostsLoki = config.homelab.services.loki.enable or false;

  lokiUrl =
    if selfHostsLoki
    then "http://127.0.0.1:${toString (config.homelab.services.loki.lokiPort or 3100)}/loki/api/v1/push"
    else cfg.lokiPushUrl;

  mimirUrl =
    if selfHostsLoki
    then "http://127.0.0.1:${toString (config.homelab.services.loki.mimirPort or 9009)}/api/v1/push"
    else cfg.mimirPushUrl;

  syslogCfg = cfg.syslogReceiver;

  # Plain IP/CIDR → regex for the connection-IP relabel match. Dots escaped,
  # slashes stripped (CIDR bit length isn't meaningful in the regex — if you
  # want to match a whole subnet, use a wider regex in a future extension).
  ipToRegex = ip: let
    stripped = lib.head (lib.splitString "/" ip);
  in
    lib.replaceStrings ["."] ["\\."] stripped;

  syslogSourceRules = lib.concatMapStringsSep "\n" (src: ''

    rule {
      source_labels = ["__syslog_connection_ip_address"]
      regex         = ${builtins.toJSON (ipToRegex src.ip)}
      replacement   = ${builtins.toJSON src.label}
      target_label  = "host"
    }'')
  syslogCfg.sources;

  syslogBlocks = lib.optionalString syslogCfg.enable ''
    loki.relabel "syslog" {
      forward_to = []${syslogSourceRules}

      rule {
        source_labels = ["__syslog_message_app_name"]
        target_label  = "app"
      }
      rule {
        source_labels = ["__syslog_message_severity"]
        target_label  = "severity"
      }
      rule {
        source_labels = ["__syslog_message_facility"]
        target_label  = "facility"
      }
    }

    loki.source.syslog "network" {
      listener {
        address        = "${syslogCfg.listenAddress}:${toString syslogCfg.port}"
        protocol       = "udp"
        syslog_format  = "rfc3164"
        labels         = { source = "syslog", transport = "udp" }
      }
      listener {
        address        = "${syslogCfg.listenAddress}:${toString syslogCfg.port}"
        protocol       = "tcp"
        syslog_format  = "rfc3164"
        labels         = { source = "syslog", transport = "tcp" }
      }
      forward_to    = [loki.write.loki.receiver]
      relabel_rules = loki.relabel.syslog.rules
    }
  '';

  # Generate extra scrape blocks for additional targets
  extraScrapeBlocks = lib.concatMapStringsSep "\n" (target: let
    hasRelabels = target.labelRewrites != {};
    # Emit one rule per source-label per raw-value. Each rule matches the
    # exact raw value and rewrites the label to the friendly value.
    # Alloy/prom relabel regexes are anchored — use ^...$ to avoid partial
    # matches (e.g. "igc1" would otherwise also match "igc1.10").
    relabelRules = lib.concatStringsSep "\n" (
      lib.flatten (
        lib.mapAttrsToList (
          labelName: valueMap:
            lib.mapAttrsToList (rawValue: friendly: ''
              rule {
                source_labels = ["${labelName}"]
                regex         = "^${rawValue}$"
                replacement   = "${friendly}"
                target_label  = "${labelName}"
              }
            '')
            valueMap
        )
        target.labelRewrites
      )
    );
    forwardTo =
      if hasRelabels
      then "[prometheus.relabel.${target.job}.receiver]"
      else "[prometheus.remote_write.mimir.receiver]";
  in
    ''
      prometheus.scrape "${target.job}" {
        targets = [{
          __address__ = "${target.address}",
          instance    = "${
        if target.instance != ""
        then target.instance
        else target.job
      }",${lib.optionalString (target.targetParam != null) ''
          __param_target = "${target.targetParam}",''}
        }]
        forward_to      = ${forwardTo}
        scrape_interval = "60s"
        job_name        = "${target.job}"
      }
    ''
    + lib.optionalString hasRelabels ''

      prometheus.relabel "${target.job}" {
        forward_to = [prometheus.remote_write.mimir.receiver]
      ${relabelRules}
      }
    '')
  cfg.extraScrapeTargets;

  # Scrape the local process-exporter when it's running (homelab.prometheus.
  # processExporter.enable, on by default fleet-wide). Gated on the upstream
  # exporter option directly so this stays correct if the port/enable changes.
  # Localhost-only target — the exporter binds 127.0.0.1 (see prometheus.nix).
  processScrapeBlock = lib.optionalString config.services.prometheus.exporters.process.enable ''
    prometheus.scrape "process" {
      targets = [{
        __address__ = "localhost:${toString config.services.prometheus.exporters.process.port}",
        instance    = "${config.networking.hostName}",
      }]
      forward_to      = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "60s"
      job_name        = "process"
    }
  '';

  alloyConfig = pkgs.writeText "alloy-loki.hcl" ''
    loki.write "loki" {
      endpoint {
        url = "${lokiUrl}"
        // doc2 (which currently hosts Loki) auto-reboots nightly and is
        // unreachable for ~10-15 min. Default max_backoff_period=5m made
        // alloy exhaust retries at ~9 min and drop batches. Bump so the
        // in-memory queue rides through normal maintenance windows; the
        // WAL below covers anything longer. See RCA 2026-05-21.
        max_backoff_period = "10m"
      }

      // Persist queued batches to /var/lib/alloy so we don't lose logs
      // when Loki is briefly down OR when alloy itself restarts. WAL is
      // off by default in alloy; prometheus.remote_write to Mimir already
      // has its own on-disk WAL, so this closes the symmetric gap on the
      // Loki side. max_segment_age caps how stale a replayed segment can
      // be — older than that and we accept the loss rather than ship
      // hours-old logs.
      wal {
        enabled         = true
        max_segment_age = "2h"
      }
    }

    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal__priority"]
        target_label  = "priority"
      }

      rule {
        source_labels = ["__journal__transport"]
        target_label  = "transport"
      }

      rule {
        source_labels = ["__journal_container_name"]
        target_label  = "container"
      }
    }

    loki.process "filter" {
      forward_to = [loki.write.loki.receiver]

      stage.drop {
        expression          = "health_status:"
        drop_counter_reason = "health_check_noise"
      }

      stage.drop {
        expression          = "container sync [0-9a-f]"
        drop_counter_reason = "container_sync_noise"
      }

      stage.drop {
        expression          = "celery\\.beat.*Waking up"
        drop_counter_reason = "celery_beat_wakeup"
      }

      stage.drop {
        expression          = "caller=metrics\\.go.+query="
        drop_counter_reason = "loki_query_metrics"
      }

      stage.drop {
        expression          = "already been recorded in the archive"
        drop_counter_reason = "ytdlp_archive_skip"
      }
    }

    // path=/var/log/journal/ enumerates all machine subdirs so
    // systemd-nspawn container journals reach Loki (otherwise sd_journal
    // opens only the host's namespace). NOTE: in practice this alone is
    // insufficient for nspawn inner-unit logs — sd_journal_open still
    // scopes to the host's machine-id. The actual working path for inner
    // postgres/mariadb logs is the syslog-bindmount workaround in
    // mk-pg-container.nix. We keep this here as defence-in-depth.
    // See docs/wiki/infrastructure/nspawn-journal-shipping.md.
    loki.source.journal "read" {
      forward_to    = [loki.process.filter.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = { source = "journald", host = "${config.networking.hostName}" }
      path          = "/var/log/journal/"
    }

    prometheus.scrape "node" {
      targets = [{
        __address__ = "localhost:9100",
        instance    = "${config.networking.hostName}",
      }]
      forward_to      = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "60s"
      job_name        = "node"
    }

    ${processScrapeBlock}

    ${extraScrapeBlocks}

    ${syslogBlocks}

    prometheus.remote_write "mimir" {
      endpoint {
        url = "${mimirUrl}"
      }
      external_labels = {
        host = "${config.networking.hostName}",
      }
    }
  '';
in {
  options.homelab.loki = {
    enable = lib.mkEnableOption "Ship journald logs and node metrics to the LGTM stack";

    lokiPushUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://loki.ablz.au./loki/api/v1/push";
      description = ''
        Full URL for Loki's push endpoint. Default uses the Cloudflare FQDN
        which resolves to whichever host currently runs
        `homelab.services.loki` (the localProxy module owns the A record).
        Ignored when `homelab.services.loki.enable = true` on this host —
        that case short-circuits to localhost.

        NOTE the trailing dot ("loki.ablz.au.") — it is LOAD-BEARING, not a
        typo. It roots the name so a host with `search ablz.au` can never
        search-suffix a failed `loki.ablz.au` lookup into
        `loki.ablz.au.ablz.au` → the `*.ablz.au` wildcard → caddy, which
        421s every push and wedges alloy forever. The NixOS fleet only
        dodged this by rebooting nightly; the dot makes it structural.
        Full RCA: docs/wiki/services/lgtm-stack.md (2026-06-19).
      '';
    };

    mimirPushUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://mimir.ablz.au./api/v1/push";
      description = ''
        Full URL for Mimir's remote_write endpoint. Default uses the
        Cloudflare FQDN — see lokiPushUrl for rationale (incl. the
        load-bearing trailing dot).
      '';
    };

    syslogReceiver = {
      enable = lib.mkEnableOption "Syslog receiver for network devices";
      port = lib.mkOption {
        type = lib.types.port;
        default = 1514;
        description = "Port to listen for syslog (UDP+TCP).";
      };
      listenAddress = lib.mkOption {
        type = lib.types.str;
        # BIND-ALL-INTERFACES-OK: the alloy syslog receiver ingests from
        # off-host senders (e.g. pfSense → 1514); the firewall scopes who may
        # reach it (1514 allowed only from 192.168.1.1). Must not be localhost.
        default = "0.0.0.0";
        description = "Address to bind syslog listener.";
      };
      sources = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            ip = lib.mkOption {
              type = lib.types.str;
              description = ''
                Sender IP (or CIDR like 192.168.1.0/24). Used for both the
                firewall accept rule on the syslog port AND the alloy
                relabel rule that stamps the friendly host label. Only exact
                IP matches are relabelled; CIDRs are accepted by the
                firewall but the relabel regex falls back to the network
                address, so explicit per-host entries are usually what you
                want.
              '';
              example = "192.168.1.1";
            };
            label = lib.mkOption {
              type = lib.types.str;
              description = "Friendly host label to stamp on matching syslog lines.";
              example = "pfsense";
            };
          };
        });
        default = [];
        description = ''
          Syslog senders allowed through the firewall and relabelled with a
          friendly host name. If empty with syslogReceiver.enable = true,
          the receiver listens but no traffic will reach it.
        '';
      };
    };

    extraScrapeTargets = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          job = lib.mkOption {
            type = lib.types.str;
            description = "Prometheus job name";
          };
          address = lib.mkOption {
            type = lib.types.str;
            description = ''
              Target address (host:port). Prefer DNS hostnames over hardcoded
              IPs — hardcoded IPs break silently when hosts are renumbered.
            '';
          };
          instance = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Instance label (defaults to job name)";
          };
          targetParam = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              If set, passed as `?target=<value>` query parameter. Used by
              multi-target exporters (snmp_exporter, pfsense_exporter, etc.)
              where `address` is the exporter and `targetParam` is the device
              being scraped.
            '';
          };
          labelRewrites = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
            default = {};
            description = ''
              Label-value rewrites applied at scrape time (alloy
              `prometheus.relabel`). Map of `label_name` → { raw_value =
              friendly_value; ... }. Useful for renaming upstream-exporter
              values that are meaningless to humans (e.g. ntopng's
              `ifname = "igc0"` → "WAN").

              Example:
                labelRewrites.ifname = {
                  igc0 = "WAN";
                  igc1 = "LAN";
                };
            '';
            example = {
              ifname = {
                igc0 = "WAN";
                igc1 = "LAN";
              };
            };
          };
        };
      });
      default = [];
      description = "Additional Prometheus scrape targets for this host.";
    };

    # ----------------------------------------------------------------
    # pfSense Prometheus exporter (OCI on the host running loki)
    # ----------------------------------------------------------------
    pfsenseExporter = {
      enable = lib.mkEnableOption "pfSense Prometheus exporter via REST API (OCI)";

      pfsenseHost = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.1";
        description = ''
          pfSense host address. Hardcoded IP is an accepted exception to the
          DNS-first rule — pfSense IS the gateway/router by network design
          and has no localProxy-managed FQDN.
        '';
      };

      pfsensePort = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "pfSense HTTPS port.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9945;
        description = "Host port the exporter listens on (exposes /metrics).";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/pfrest/pfsense_exporter:latest";
        description = "OCI image for the pfSense exporter.";
      };
    };

    # ----------------------------------------------------------------
    # ntopng exporter — per-client IP traffic metrics
    # ----------------------------------------------------------------
    # Depends on ntopng installed + running on a pfSense host (see
    # docs/wiki/services/lgtm-stack.md). The exporter polls ntopng's
    # REST API and exposes metrics with labels `ip`, `mac`, `ifname`,
    # letting us break bandwidth down per-client and per-interface.
    #
    # OPERATIONAL GOTCHAS (see wiki §"ntopng has two rc scripts" +
    # §"Service Watchdog needs ntopng registered"):
    #   - The hardcoded `https://` endpoint is correct, but pfSense's
    #     `service ntopng onestart` silently starts ntopng without SSL.
    #     Always restart via `/usr/local/etc/rc.d/ntopng.sh restart`.
    #   - pfSense Service Watchdog needs ntopng in
    #     `installedpackages/service[]` (rcfile=ntopng.sh) or it silently
    #     no-ops on "restart". See `.claude/agents/pfsense.md` for the
    #     injected config.xml entry.
    #   - ntopng's `--dns-mode` is currently 2 (passive decode). Mode 1
    #     created loopback PTR storms that saturated pfSense unbound.
    #     See docs/wiki/infrastructure/pfsense-dns-resolver.md.
    ntopngExporter = {
      enable = lib.mkEnableOption "ntopng per-client traffic exporter (OCI)";

      ntopngUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://192.168.1.1:3000";
        description = ''
          Base URL of ntopng's REST API on pfSense. Hardcoded IP is an
          accepted DNS-first exception — pfSense IS the gateway and has
          no localProxy-managed FQDN.
        '';
      };

      allowUnsafeTLS = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Accept pfSense's self-signed webgui TLS cert (ntopng reuses it).
          Safe because the connection stays on the LAN.
        '';
      };

      interfacesToMonitor = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["igc0" "igc1" "igc1.10" "igc1.100" "tun_wg0" "tun_wg2"];
        description = ''
          Real device names (not pfSense "lan"/"wan" labels) that ntopng
          is monitoring. Query
            curl -k --cookie "user=admin; password=..." \
              https://pfsense/lua/rest/v1/get/ntopng/interfaces.lua
          to list them. Must match ntopng's `ifname` values or the
          exporter emits empty series.
        '';
      };

      ifnameAliases = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "igc0" = "WAN";
          "igc1" = "LAN";
          "igc1.10" = "Docker VLAN";
          "igc1.100" = "IoT VLAN";
          "tun_wg0" = "AirVPN SG";
          "tun_wg2" = "AirVPN NZ";
        };
        description = ''
          Device-name → friendly-name rewrites applied to the `ifname`
          label at scrape time (via alloy's prometheus.relabel). Dashboard
          variable queries pick up the friendly names automatically.
          Keys must be exact ntopng `ifname` values; see interfacesToMonitor.
        '';
      };

      localSubnets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "192.168.1.0/24" # LAN
          "192.168.11.0/24" # DockerVLAN
          "192.168.101.0/24" # IoT
          "224.0.0.0/4" # multicast (for mDNS etc.)
        ];
        description = ''
          Cardinality filter — only hosts in these CIDRs become Prometheus
          series. Without this, every public-internet destination you ever
          touch creates a new timeseries and Mimir fills up.
        '';
      };

      scrapeInterval = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "How often the exporter polls ntopng (matches alloy scrape interval).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9946;
        description = "Host port the exporter listens on (exposes /metrics).";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "docker.io/aauren/ntopng-exporter:latest";
        description = "OCI image for the ntopng exporter.";
      };

      vpnClientIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["192.168.1.18" "192.168.1.36"];
        description = ''
          LAN IPs that pfSense policy-routes through AirVPN (i.e. the
          `MV_VPN_IPS` alias on pfSense). Consumed by the "ntopng —
          Client Traffic" custom dashboard to tag which LAN hosts are
          actively using the VPN.

          ntopng structurally cannot break down VPN tunnel traffic by
          LAN client (the clients are NAT'd behind the tunnel), so the
          dashboard infers VPN usage from policy-routing membership on
          the LAN side. This list is that membership.

          Fleet-sync rule: this MUST be kept in sync with pfSense's
          MV_VPN_IPS alias. When you add or remove an IP from
          MV_VPN_IPS on pfSense, update this option AND redeploy the
          host running `homelab.services.loki` (i.e. doc2). The
          dashboard regex is baked in at Nix build time — a drift
          between Nix and pfSense silently mis-tags hosts in the UI
          without producing an error.

          The pfsense subagent (.claude/agents/pfsense.md) has a
          front-matter maintenance rule enforcing this sync.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # ============================================================
    # Alloy shipper (every host with homelab.loki.enable)
    # ============================================================
    (lib.mkIf cfg.enable {
      networking.firewall = lib.mkMerge [
        (lib.mkIf (syslogCfg.enable && syslogCfg.sources != []) {
          extraCommands =
            lib.concatMapStringsSep "\n" (src: ''
              iptables  -I nixos-fw 1 -p udp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept
              iptables  -I nixos-fw 1 -p tcp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept
              ip6tables -I nixos-fw 1 -p udp --dport ${toString syslogCfg.port} -s ::1 -j nixos-fw-accept 2>/dev/null || true
            '')
            syslogCfg.sources;
          extraStopCommands =
            lib.concatMapStringsSep "\n" (src: ''
              iptables  -D nixos-fw -p udp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept 2>/dev/null || true
              iptables  -D nixos-fw -p tcp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept 2>/dev/null || true
            '')
            syslogCfg.sources;
        })
      ];

      systemd.tmpfiles.rules = [
        "d /var/lib/alloy 0755 root root - -"
      ];

      systemd.services.alloy-loki = {
        description = "Grafana Alloy journald shipper (Loki)";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          NoNewPrivileges = true; # alloy Go binary reads journald; no setuid exec (#232)
          ExecStart = "${pkgs.grafana-alloy}/bin/alloy run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy --disable-reporting ${alloyConfig}";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      # See #253 audit + rules-doc "Per-service errorPatterns".
      # HIGHEST priority: when alloy drops batches, we lose logs — every
      # other alert in this stack assumes logs are reaching Loki, so this
      # is the canary on the canary. `failed to register collector with
      # remote server` is benign noop-client startup chatter, excluded.
      homelab.monitoring.errorPatterns = [
        {
          name = "Alloy dropping log batches";
          unit = "alloy-loki.service";
          pattern = "(?i)final error sending batch, no retries left, dropping data";
          severity = "critical";
          summary = "alloy gave up on a log batch — we are losing logs";
          description = ''
            All Loki-based alerts assume logs are arriving. This alert
            fires when alloy exhausts retries and DROPS a batch — meaning
            other service alerts in this same time window may have been
            silenced by the data loss. Investigate the Loki ingester
            state, network to Loki, and disk pressure on /var/lib/alloy.
          '';
          # 2026-06-28: this critical was false-paging (~46 hits/7d). A
          # doc2/Loki NIGHTLY REBOOT makes every host's alloy drop a batch
          # simultaneously (≥3 in one 5m window → count>2 trips instantly
          # at forDuration=0s). But those drops are recovered from the WAL
          # on /var/lib/alloy (see the alloy config above) — no logs are
          # actually lost. Require the drop to PERSIST past a reboot cycle
          # so only a sustained Loki outage (WAL filling, ingester down for
          # real) pages. See rules-doc "forDuration — transient bursts".
          forDuration = "15m";
        }
      ];
    })

    # ============================================================
    # pfSense Prometheus exporter (doc2 — the observability host)
    # ============================================================
    (lib.mkIf cfg.pfsenseExporter.enable (let
      pfeCfg = cfg.pfsenseExporter;

      configTemplate = pkgs.writeText "pfsense-exporter-config.yml" ''
        address: 0.0.0.0
        port: ${toString pfeCfg.port}
        targets:
          - host: ${pfeCfg.pfsenseHost}
            port: ${toString pfeCfg.pfsensePort}
            scheme: https
            auth_method: key
            key: __PFSENSE_API_KEY__
            validate_cert: false
            timeout: 30
            # Upstream buffers each collector before forwarding any metrics.
            # The default 100 deadlocks once a collector emits >100 series
            # (this pfSense's interface collector does). Keep the bound ample
            # but finite; four concurrent collectors make this inexpensive.
            max_collector_buffer_size: 1000
      '';

      preStartScript = pkgs.writeShellScript "pfsense-exporter-prestart" ''
        set -euo pipefail
        config_dir="/var/lib/pfsense-exporter"
        mkdir -p "$config_dir"

        env_file="/run/secrets/pfsense-exporter/env"
        if [[ ! -r "$env_file" ]]; then
          echo "pfsense-exporter: sops env not readable: $env_file" >&2
          exit 1
        fi

        api_key=$(${pkgs.gnugrep}/bin/grep -m1 '^PFSENSE_API_KEY=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        ${pkgs.gnused}/bin/sed "s/__PFSENSE_API_KEY__/$api_key/" \
          ${configTemplate} > "$config_dir/config.yml"
        chmod 600 "$config_dir/config.yml"
      '';
    in {
      sops.secrets."pfsense-exporter/env" = {
        # #234: dedicated read-only key (user metrics-exporter-ro), NOT the
        # full-control pfsense-mcp.env (doc1-only). doc2-scoped.
        sopsFile = config.homelab.secrets.sopsFile "pfsense-exporter.env";
        format = "dotenv";
        mode = "0400";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/pfsense-exporter 0755 root root -"
      ];

      virtualisation.oci-containers.containers.pfsense-exporter = {
        inherit (pfeCfg) image;
        autoStart = true;
        pull = "newer";
        ports = ["${toString pfeCfg.port}:${toString pfeCfg.port}"];
        volumes = [
          "/var/lib/pfsense-exporter/config.yml:/pfsense_exporter/config.yml:ro"
        ];
        # Static Go exporter: binds one unprivileged port, scrapes pfSense over
        # HTTP. Needs no Linux capabilities — cap-drop=all + no-new-privileges.
        extraOptions = config.homelab.podman.hardenOptions;
      };

      systemd.services.podman-pfsense-exporter.serviceConfig.ExecStartPre =
        lib.mkBefore [preStartScript];

      homelab = {
        podman.enable = true;
        podman.containers = [
          {
            unit = "podman-pfsense-exporter.service";
            inherit (pfeCfg) image;
          }
        ];

        loki.extraScrapeTargets = [
          {
            job = "pfsense";
            address = "localhost:${toString pfeCfg.port}";
            instance = "pfsense";
            targetParam = pfeCfg.pfsenseHost;
          }
        ];

        monitoring.monitors = [
          {
            name = "pfSense Exporter";
            url = "http://localhost:${toString pfeCfg.port}/metrics?target=${pfeCfg.pfsenseHost}";
          }
        ];
      };
    }))

    # ============================================================
    # ntopng exporter (doc2 — per-client traffic from pfSense)
    # ============================================================
    (lib.mkIf cfg.ntopngExporter.enable (let
      neCfg = cfg.ntopngExporter;

      # Exporter config template. Password placeholder is substituted at
      # service start from the sops-decrypted env file so creds never hit
      # the Nix store. Format: YAML (a superset of JSON, so we can use
      # builtins.toJSON for the mechanically-generated parts and sed in
      # the password at runtime).
      ntopngConfig = pkgs.writeText "ntopng-exporter-config.yml" (lib.generators.toYAML {} {
        ntopng = {
          endpoint = neCfg.ntopngUrl;
          inherit (neCfg) allowUnsafeTLS;
          user = "__NTOPNG_USER__";
          password = "__NTOPNG_PASSWORD__";
          authMethod = "cookie";
          inherit (neCfg) scrapeInterval;
          scrapeTargets = ["hosts" "interfaces" "l7protocols"];
        };
        host = {
          inherit (neCfg) interfacesToMonitor;
        };
        metric = {
          localSubnetsOnly = neCfg.localSubnets;
          excludeDNSMetrics = false;
          serve = {
            ip = "0.0.0.0";
            inherit (neCfg) port;
          };
        };
      });

      preStartScript = pkgs.writeShellScript "ntopng-exporter-prestart" ''
        set -euo pipefail
        config_dir="/var/lib/ntopng-exporter"
        mkdir -p "$config_dir"

        env_file="/run/secrets/ntopng-exporter/env"
        if [[ ! -r "$env_file" ]]; then
          echo "ntopng-exporter: sops env not readable: $env_file" >&2
          exit 1
        fi

        user=$(${pkgs.gnugrep}/bin/grep -m1 '^NTOPNG_USER=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        password=$(${pkgs.gnugrep}/bin/grep -m1 '^NTOPNG_PASSWORD=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)

        ${pkgs.gnused}/bin/sed \
          -e "s|__NTOPNG_USER__|$user|" \
          -e "s|__NTOPNG_PASSWORD__|$password|" \
          ${ntopngConfig} > "$config_dir/ntopng-exporter.yaml"
        chmod 600 "$config_dir/ntopng-exporter.yaml"
      '';
    in {
      sops.secrets."ntopng-exporter/env" = {
        sopsFile = config.homelab.secrets.sopsFile "ntopng.env";
        format = "dotenv";
        mode = "0400";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/ntopng-exporter 0755 root root -"
      ];

      virtualisation.oci-containers.containers.ntopng-exporter = {
        inherit (neCfg) image;
        autoStart = true;
        pull = "newer";
        ports = ["${toString neCfg.port}:${toString neCfg.port}"];
        # Exporter Dockerfile expects /config/ntopng-exporter.yaml.
        volumes = [
          "/var/lib/ntopng-exporter:/config:ro"
        ];
        # Static Go exporter: binds one unprivileged port, scrapes ntopng over
        # HTTP. Needs no Linux capabilities — cap-drop=all + no-new-privileges.
        extraOptions = config.homelab.podman.hardenOptions;
      };

      systemd.services.podman-ntopng-exporter.serviceConfig.ExecStartPre =
        lib.mkBefore [preStartScript];

      homelab = {
        podman.enable = true;
        podman.containers = [
          {
            unit = "podman-ntopng-exporter.service";
            inherit (neCfg) image;
          }
        ];

        loki.extraScrapeTargets = [
          {
            job = "ntopng";
            address = "localhost:${toString neCfg.port}";
            instance = "ntopng";
            labelRewrites.ifname = neCfg.ifnameAliases;
          }
        ];

        monitoring.monitors = [
          {
            name = "ntopng Exporter";
            url = "http://localhost:${toString neCfg.port}/metrics";
          }
        ];
      };
    }))
  ];
}
