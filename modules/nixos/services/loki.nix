{
  config,
  lib,
  pkgs,
  allHosts,
  ...
}: let
  cfg = config.homelab.loki;
  lokiHosts = lib.attrNames (
    lib.filterAttrs (
      _: host:
        (host ? containerStacks)
        && lib.elem "loki" host.containerStacks
    )
    allHosts
  );
  autoHostName =
    if lokiHosts != []
    then builtins.head (lib.sort lib.lessThan lokiHosts)
    else null;
  hostName =
    if cfg.host != null
    then cfg.host
    else autoHostName;
  lokiHost =
    if hostName != null
    then allHosts.${hostName} or null
    else null;
  lokiIp =
    if lokiHost != null && lokiHost ? localIp
    then lokiHost.localIp
    else hostName;
  lokiUrl =
    if lokiIp != null
    then "http://${lokiIp}:${toString cfg.port}/loki/api/v1/push"
    else null;
  mimirUrl =
    if lokiIp != null
    then "http://${lokiIp}:${toString cfg.mimirPort}/api/v1/push"
    else null;

  syslogCfg = cfg.syslogReceiver;

  syslogBlocks = lib.optionalString syslogCfg.enable ''
    loki.relabel "syslog" {
      forward_to = []

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "192\\.168\\.1\\.1"
        replacement   = "pfsense"
        target_label  = "host"
      }
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

    loki.source.journal "read" {
      forward_to    = [loki.write.loki.receiver]
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
    enable = lib.mkEnableOption "Ship journald logs to Loki";

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "hosts.nix name for the Loki host. Null picks the first host with the loki stack.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Loki HTTP port.";
    };

    mimirPort = lib.mkOption {
      type = lib.types.port;
      default = 9009;
      description = "Mimir HTTP port for remote_write.";
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
            description = "Target address (host:port)";
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lokiUrl != null;
        message = "homelab.loki: no Loki host detected; set homelab.loki.host or add loki stack to a host with localIp.";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf syslogCfg.enable [syslogCfg.port];
    networking.firewall.allowedUDPPorts = lib.mkIf syslogCfg.enable [syslogCfg.port];

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
  };
}
