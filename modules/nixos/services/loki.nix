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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lokiUrl != null;
        message = "homelab.loki: no Loki host detected; set homelab.loki.host or add loki stack to a host with localIp.";
      }
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
        ExecStart = "${pkgs.grafana-alloy}/bin/alloy run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy ${alloyConfig}";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
