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

  promtailConfig = pkgs.writeText "promtail-loki.yaml" ''
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /var/lib/promtail/positions.yaml

    clients:
      - url: ${lokiUrl}

    scrape_configs:
      - job_name: systemd-journal
        journal:
          path: /var/log/journal
          max_age: 24h
          labels:
            job: systemd-journal
            host: ${config.networking.hostName}
        relabel_configs:
          - source_labels: ['__journal__systemd_unit']
            target_label: 'systemd_unit'
          - source_labels: ['__journal__transport']
            target_label: 'transport'
          - source_labels: ['__journal_priority']
            target_label: 'priority'
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
      "d /var/lib/promtail 0755 root root - -"
    ];

    systemd.services.promtail-loki = {
      description = "Promtail journald shipper (Loki)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${pkgs.promtail}/bin/promtail -config.file=${promtailConfig}";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
