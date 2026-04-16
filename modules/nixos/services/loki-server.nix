# LGTM observability stack (Grafana + Loki + Tempo + Mimir) for doc2.
# Architecture, gotchas, and migration runbook: docs/wiki/services/lgtm-stack.md
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.homelab.services.loki;

  # Declarative dashboards live in a per-deploy directory — grafana's
  # provisioning watches this path and loads any JSON files as dashboards.
  # Sourced from flake inputs so nightly rolling-flake-update.service picks
  # up upstream dashboard changes automatically; no manual hash bumps.
  dashboardsDir = pkgs.runCommand "grafana-dashboards" {} ''
    mkdir -p $out

    # Node Exporter Full (grafana.com/dashboards/1860) — fleet-wide
    # CPU/memory/disk/network views.
    cp ${inputs.grafana-dashboards-rfmoz}/prometheus/node-exporter-full.json \
      $out/node-exporter-full.json

    # pfSense exporter dashboards — co-versioned with the scrape metrics.
    cp ${inputs.pfsense-exporter-src}/dashboards/*.json $out/
  '';
in {
  options.homelab.services.loki = {
    enable = lib.mkEnableOption "LGTM observability stack (Grafana + Loki + Tempo + Mimir)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/loki-stack";
      description = "Parent directory for all LGTM state (grafana/, loki/, tempo/, mimir/ subdirs).";
    };

    retentionHours = lib.mkOption {
      type = lib.types.int;
      default = 744;
      description = "Loki log retention in hours (default: 31 days).";
    };

    grafanaPort = lib.mkOption {
      type = lib.types.port;
      default = 3030;
      # Not 3000 — mealie's gotenberg sidecar binds 127.0.0.1:3000 on doc2.
      # Not 3001 — uptime-kuma. 3030 is the conventional grafana-alt port.
      description = "Grafana HTTP port. Bound to 127.0.0.1 — reached via logs.ablz.au through nginx.";
    };

    lokiPort = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Loki HTTP port. Bound to 0.0.0.0 so off-host exporters (tower/Unraid) can push.";
    };

    tempoPort = lib.mkOption {
      type = lib.types.port;
      default = 3200;
      description = "Tempo HTTP port.";
    };

    tempoOtlpGrpcPort = lib.mkOption {
      type = lib.types.port;
      default = 4317;
      description = "Tempo OTLP gRPC receiver port.";
    };

    tempoOtlpHttpPort = lib.mkOption {
      type = lib.types.port;
      default = 4318;
      description = "Tempo OTLP HTTP receiver port.";
    };

    mimirPort = lib.mkOption {
      type = lib.types.port;
      default = 9009;
      description = "Mimir HTTP port. Bound to 0.0.0.0 so off-host exporters can remote_write.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Parent + per-component state dirs. Grafana/Loki own their subdirs via
    # upstream modules (static users); tempo/mimir have DynamicUser upstream
    # so we create static users below and tmpfiles owns those subdirs for us.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}          0755 root    root    - -"
      "d ${cfg.dataDir}/grafana  0750 grafana grafana - -"
      "d ${cfg.dataDir}/loki     0750 loki    loki    - -"
      "d ${cfg.dataDir}/tempo    0750 tempo   tempo   - -"
      "d ${cfg.dataDir}/mimir    0750 mimir   mimir   - -"
    ];

    # -------- Grafana --------
    services.grafana = {
      enable = true;
      dataDir = "${cfg.dataDir}/grafana";
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = cfg.grafanaPort;
          domain = "logs.ablz.au";
          root_url = "https://logs.ablz.au";
        };
        security = {
          admin_user = "$__env{GRAFANA_ADMIN_USER}";
          admin_password = "$__env{GRAFANA_ADMIN_PASSWORD}";
          # Env provider so the key stays out of the Nix store. Seeded to
          # Grafana's historical upstream default so an old grafana.db from
          # the compose-era stack would still decrypt; rotate later if any
          # real secrets land in the DB.
          secret_key = "$__env{GRAFANA_SECRET_KEY}";
        };
        users.allow_sign_up = false;
        analytics.reporting_enabled = false;
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString cfg.lokiPort}";
            isDefault = true;
          }
          {
            name = "Tempo";
            type = "tempo";
            access = "proxy";
            url = "http://127.0.0.1:${toString cfg.tempoPort}";
          }
          {
            name = "Mimir";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString cfg.mimirPort}/prometheus";
          }
        ];

        # Dashboard provisioning. Files in `path` are auto-loaded on grafana
        # start (and re-scanned every `updateIntervalSeconds`). Source of
        # truth is the flake-input repo, so nightly flake updates bring in
        # upstream dashboard revisions without manual hash bumps.
        dashboards.settings.providers = [
          {
            name = "flake-inputs";
            type = "file";
            disableDeletion = true;
            updateIntervalSeconds = 300;
            options.path = dashboardsDir;
          }
        ];
      };
    };

    # Grafana admin creds injected via env so they never hit the Nix store.
    systemd.services.grafana.serviceConfig.EnvironmentFile =
      config.sops.secrets."loki/grafana.env".path;

    # -------- Loki --------
    services.loki = {
      enable = true;
      dataDir = "${cfg.dataDir}/loki";
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "0.0.0.0";
          http_listen_port = cfg.lokiPort;
          # Each dskit-based service defaults gRPC to :9095 — collides when
          # loki+tempo+mimir share a host. Spread them and bind to loopback.
          # dskit ring advertises the resolved host IP, not the listen address —
          # binding to 127.0.0.1 breaks single-host ring self-discovery. Firewall
          # still keeps 9095/9096/9097 off the LAN.
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9096;
        };
        common = {
          path_prefix = "${cfg.dataDir}/loki";
          replication_factor = 1;
          ring.kvstore.store = "inmemory";
          storage.filesystem = {
            chunks_directory = "${cfg.dataDir}/loki/chunks";
            rules_directory = "${cfg.dataDir}/loki/rules";
          };
        };
        schema_config.configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        storage_config.tsdb_shipper = {
          active_index_directory = "${cfg.dataDir}/loki/index";
          cache_location = "${cfg.dataDir}/loki/index_cache";
        };
        compactor = {
          working_directory = "${cfg.dataDir}/loki/compactor";
          compaction_interval = "10m";
          retention_enabled = true;
          retention_delete_delay = "2h";
          delete_request_store = "filesystem";
        };
        limits_config.retention_period = "${toString cfg.retentionHours}h";
        ruler = {
          storage = {
            type = "local";
            local.directory = "${cfg.dataDir}/loki/rules";
          };
          rule_path = "${cfg.dataDir}/loki/rules-temp";
          ring.kvstore.store = "inmemory";
          enable_api = true;
        };
        analytics.reporting_enabled = false;
      };
    };

    # -------- Tempo --------
    # Static user so data on virtiofs survives without DynamicUID churn.
    users.users.tempo = {
      isSystemUser = true;
      group = "tempo";
      home = "${cfg.dataDir}/tempo";
    };
    users.groups.tempo = {};

    services.tempo = {
      enable = true;
      settings = {
        server = {
          http_listen_address = "0.0.0.0";
          http_listen_port = cfg.tempoPort;
          # dskit ring advertises the resolved host IP, not the listen address —
          # binding to 127.0.0.1 breaks single-host ring self-discovery. Firewall
          # still keeps 9095/9096/9097 off the LAN.
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9095;
        };
        distributor.receivers.otlp.protocols = {
          grpc.endpoint = "0.0.0.0:${toString cfg.tempoOtlpGrpcPort}";
          http.endpoint = "0.0.0.0:${toString cfg.tempoOtlpHttpPort}";
        };
        ingester.max_block_duration = "5m";
        storage.trace = {
          backend = "local";
          local.path = "${cfg.dataDir}/tempo";
          wal.path = "${cfg.dataDir}/tempo/wal";
        };
        usage_report.reporting_enabled = false;
      };
    };

    systemd.services.tempo.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "tempo";
      Group = "tempo";
      WorkingDirectory = lib.mkForce "${cfg.dataDir}/tempo";
      StateDirectory = lib.mkForce "";
      ReadWritePaths = ["${cfg.dataDir}/tempo"];
    };

    # -------- Mimir --------
    users.users.mimir = {
      isSystemUser = true;
      group = "mimir";
      home = "${cfg.dataDir}/mimir";
    };
    users.groups.mimir = {};

    services.mimir = {
      enable = true;
      configuration = {
        multitenancy_enabled = false;
        server = {
          http_listen_address = "0.0.0.0";
          http_listen_port = cfg.mimirPort;
          # dskit ring advertises the resolved host IP, not the listen address —
          # binding to 127.0.0.1 breaks single-host ring self-discovery. Firewall
          # still keeps 9095/9096/9097 off the LAN.
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9097;
        };
        common.storage = {
          backend = "filesystem";
          filesystem.dir = "${cfg.dataDir}/mimir";
        };
        blocks_storage = {
          backend = "filesystem";
          filesystem.dir = "${cfg.dataDir}/mimir/blocks";
          tsdb.dir = "${cfg.dataDir}/mimir/tsdb";
        };
        ingester.ring.replication_factor = 1;
        compactor.data_dir = "${cfg.dataDir}/mimir/compactor";
        usage_stats.enabled = false;
      };
    };

    systemd.services.mimir.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "mimir";
      Group = "mimir";
      WorkingDirectory = lib.mkForce "${cfg.dataDir}/mimir";
      StateDirectory = lib.mkForce "";
      ReadWritePaths = ["${cfg.dataDir}/mimir"];
    };

    # -------- Firewall --------
    # HTTP endpoints (loki, tempo, mimir, grafana) are reached exclusively
    # through nginx on 443 — clients use the HTTPS FQDNs. Those ports are
    # only bound on 0.0.0.0 so nginx can reach them over localhost and so
    # the dskit ring self-discovery works; they DO NOT need to be on the
    # LAN. The only ports worth opening to the LAN are OTLP receivers so
    # future applications can push traces directly (Tempo receivers don't
    # proxy meaningfully through nginx).
    networking.firewall.allowedTCPPorts = [
      cfg.tempoOtlpGrpcPort
      cfg.tempoOtlpHttpPort
    ];

    # -------- Secrets --------
    sops.secrets."loki/grafana.env" = {
      sopsFile = config.homelab.secrets.sopsFile "loki.env";
      format = "dotenv";
      owner = "grafana";
      mode = "0400";
    };

    # -------- Proxy + Monitoring --------
    homelab = {
      localProxy.hosts = [
        {
          host = "logs.ablz.au";
          port = cfg.grafanaPort;
          websocket = true;
        }
        {
          host = "loki.ablz.au";
          port = cfg.lokiPort;
          maxBodySize = "32M";
        }
        {
          host = "tempo.ablz.au";
          port = cfg.tempoPort;
        }
        {
          host = "mimir.ablz.au";
          port = cfg.mimirPort;
          maxBodySize = "32M";
        }
      ];

      monitoring.monitors = [
        {
          name = "Grafana";
          url = "https://logs.ablz.au/api/health";
        }
        {
          name = "Loki";
          url = "https://loki.ablz.au/ready";
        }
        {
          name = "Tempo";
          url = "https://tempo.ablz.au/ready";
        }
        {
          name = "Mimir";
          url = "https://mimir.ablz.au/ready";
        }
      ];
    };
  };
}
