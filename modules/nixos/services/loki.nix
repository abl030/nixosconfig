# Alloy shipper + optional syslog receiver on every NixOS host.
# Ships journald + node_exporter to the LGTM stack via HTTPS FQDN.
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

  syslogSourceRules =
    lib.concatMapStringsSep "\n" (src: ''

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
  extraScrapeBlocks =
    lib.concatMapStringsSep "\n" (target: ''
      prometheus.scrape "${target.job}" {
        targets = [{
          __address__ = "${target.address}",
          instance    = "${
        if target.instance != ""
        then target.instance
        else target.job
      }",
        }]
        forward_to      = [prometheus.remote_write.mimir.receiver]
        scrape_interval = "60s"
        job_name        = "${target.job}"
      }
    '')
    cfg.extraScrapeTargets;

  alloyConfig = pkgs.writeText "alloy-loki.hcl" ''
    loki.write "loki" {
      endpoint {
        url = "${lokiUrl}"
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

    loki.source.journal "read" {
      forward_to    = [loki.process.filter.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = { source = "journald", host = "${config.networking.hostName}" }
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
      default = "https://loki.ablz.au/loki/api/v1/push";
      description = ''
        Full URL for Loki's push endpoint. Default uses the Cloudflare FQDN
        which resolves to whichever host currently runs
        `homelab.services.loki` (the localProxy module owns the A record).
        Ignored when `homelab.services.loki.enable = true` on this host —
        that case short-circuits to localhost.
      '';
    };

    mimirPushUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://mimir.ablz.au/api/v1/push";
      description = ''
        Full URL for Mimir's remote_write endpoint. Default uses the
        Cloudflare FQDN — see lokiPushUrl for rationale.
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
  };

  config = lib.mkMerge [
    # ============================================================
    # Alloy shipper (every host with homelab.loki.enable)
    # ============================================================
    (lib.mkIf cfg.enable {
      networking.firewall = lib.mkMerge [
        (lib.mkIf (syslogCfg.enable && syslogCfg.sources != []) {
          extraCommands = lib.concatMapStringsSep "\n" (src: ''
            iptables  -I nixos-fw 1 -p udp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept
            iptables  -I nixos-fw 1 -p tcp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept
            ip6tables -I nixos-fw 1 -p udp --dport ${toString syslogCfg.port} -s ::1 -j nixos-fw-accept 2>/dev/null || true
          '') syslogCfg.sources;
          extraStopCommands = lib.concatMapStringsSep "\n" (src: ''
            iptables  -D nixos-fw -p udp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept 2>/dev/null || true
            iptables  -D nixos-fw -p tcp --dport ${toString syslogCfg.port} -s ${src.ip} -j nixos-fw-accept 2>/dev/null || true
          '') syslogCfg.sources;
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
          ExecStart = "${pkgs.grafana-alloy}/bin/alloy run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy --disable-reporting ${alloyConfig}";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };
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
        sopsFile = config.homelab.secrets.sopsFile "pfsense-mcp.env";
        format = "dotenv";
        mode = "0400";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/pfsense-exporter 0755 root root -"
      ];

      virtualisation.oci-containers.containers.pfsense-exporter = {
        image = pfeCfg.image;
        autoStart = true;
        pull = "newer";
        ports = ["${toString pfeCfg.port}:${toString pfeCfg.port}"];
        volumes = [
          "/var/lib/pfsense-exporter/config.yml:/pfsense_exporter/config.yml:ro"
        ];
      };

      systemd.services.podman-pfsense-exporter.serviceConfig.ExecStartPre =
        lib.mkBefore [preStartScript];

      homelab = {
        podman.enable = true;
        podman.containers = [
          {
            unit = "podman-pfsense-exporter.service";
            image = pfeCfg.image;
          }
        ];

        loki.extraScrapeTargets = [
          {
            job = "pfsense";
            address = "localhost:${toString pfeCfg.port}";
            instance = "pfsense";
          }
        ];

        monitoring.monitors = [
          {
            name = "pfSense Exporter";
            url = "http://localhost:${toString pfeCfg.port}/metrics";
          }
        ];
      };
    }))
  ];
}
