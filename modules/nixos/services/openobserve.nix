{
  lib,
  config,
  allHosts,
  pkgs,
  ...
}: let
  cfg = config.homelab.openobserve;
  openobserveHosts = lib.attrNames (
    lib.filterAttrs (
      _: host:
        (host ? containerStacks)
        && lib.elem "openobserve" host.containerStacks
    )
    allHosts
  );
  autoHostName =
    if openobserveHosts != []
    then builtins.head (lib.sort lib.lessThan openobserveHosts)
    else null;
  hostName =
    if cfg.host != null
    then cfg.host
    else autoHostName;
  openobserveHost =
    if hostName != null
    then allHosts.${hostName} or null
    else null;
  openobserveIp =
    if openobserveHost != null && openobserveHost ? localIp
    then openobserveHost.localIp
    else hostName;
  endpointGrpc =
    if openobserveIp != null
    then "${openobserveIp}:${toString cfg.grpcPort}"
    else null;
  otelConfig = pkgs.writeText "openobserve-otelcol.yaml" ''
    receivers:
      journald:
        directory: /var/log/journal

    processors:
      resource:
        attributes:
          - key: host.name
            value: ${config.networking.hostName}
            action: upsert
      filter:
        logs:
          log_record:
            - 'attributes["PRIORITY"] > "${toString cfg.minPriority}"'
      batch: {}

    exporters:
      otlp/openobserve:
        endpoint: ${endpointGrpc}
        headers:
          authorization: Basic ${"$"}{env:OPENOBSERVE_AUTH}
          organization: ${cfg.org}
          stream-name: ${cfg.stream}
        tls:
          insecure: true
      debug:
        verbosity: detailed

    service:
      pipelines:
        logs:
          receivers: [journald]
          processors: [resource, filter, batch]
          exporters: [otlp/openobserve${lib.optionalString cfg.debug ", debug"}]
  '';
in {
  options.homelab.openobserve = {
    enable = lib.mkEnableOption "Ship journald logs to OpenObserve";

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "hosts.nix name for the OpenObserve host. Null picks the first host with the openobserve stack.";
    };

    grpcPort = lib.mkOption {
      type = lib.types.port;
      default = 5081;
      description = "OpenObserve OTLP gRPC port.";
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug exporter to confirm journald records are flowing.";
    };

    minPriority = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Minimum journald PRIORITY to keep (0-7). 4 = warning and above.";
    };

    org = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "OpenObserve organization header for OTLP gRPC.";
    };

    stream = lib.mkOption {
      type = lib.types.str;
      default = "journald";
      description = "OpenObserve stream name for OTLP gRPC logs.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = config.homelab.secrets.sopsFile "openobserve-agent.env";
      description = "Sops file containing OPENOBSERVE_AUTH for OTLP gRPC.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = endpointGrpc != null;
        message = "homelab.openobserve: no OpenObserve host detected; set homelab.openobserve.host or add openobserve stack to a host with localIp.";
      }
    ];

    sops.secrets."openobserve/agent" = {
      sopsFile = cfg.sopsFile;
      format = "dotenv";
      key = "OPENOBSERVE_AUTH";
      owner = "root";
      mode = "0400";
    };

    systemd.services.openobserve-agent = {
      description = "OpenObserve journald OTLP gRPC shipper";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config ${otelConfig}";
        Restart = "on-failure";
        RestartSec = "10s";
        EnvironmentFile = config.sops.secrets."openobserve/agent".path;
      };
      wantedBy = ["multi-user.target"];
    };
  };
}
