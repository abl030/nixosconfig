{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "loki-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "loki-docker-compose.yml";
  };

  grafanaDatasources = builtins.path {
    path = ./grafana-datasources.yaml;
    name = "loki-grafana-datasources.yaml";
  };

  lokiConfig = builtins.path {
    path = ./loki.yaml;
    name = "loki-config.yaml";
  };

  tempoConfig = builtins.path {
    path = ./tempo.yaml;
    name = "tempo-config.yaml";
  };

  mimirConfig = builtins.path {
    path = ./mimir.yaml;
    name = "mimir-config.yaml";
  };
  mcpContext = builtins.path {
    path = ./mcp;
    name = "loki-mcp-context";
  };

  encEnv = config.homelab.secrets.sopsFile "loki.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  inherit (config.homelab.containers) dataRoot;

  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  preStart = [
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/loki/grafana"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/loki/loki"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/loki/tempo"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/loki/mimir"
    "/run/current-system/sw/bin/chown -R 100471:100471 ${dataRoot}/loki/grafana"
    "/run/current-system/sw/bin/chown -R 110000:110000 ${dataRoot}/loki/loki"
    "/run/current-system/sw/bin/chown -R 110000:110000 ${dataRoot}/loki/tempo"
    "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/loki/mimir"
  ];

  stackHosts = [
    {
      host = "logs.ablz.au";
      port = 3001;
    }
    {
      host = "loki.ablz.au";
      port = 3100;
    }
    {
      host = "tempo.ablz.au";
      port = 3200;
    }
    {
      host = "mimir.ablz.au";
      port = 9009;
    }
    {
      host = "loki-mcp.ablz.au";
      port = 8081;
    }
  ];

  firewallPorts = [
    3001
    3100
    3200
    4317
    4318
    8081
    9009
  ];

  extraEnv = [
    "GRAFANA_DATASOURCES=${grafanaDatasources}"
    "LOKI_CONFIG=${lokiConfig}"
    "TEMPO_CONFIG=${tempoConfig}"
    "MIMIR_CONFIG=${mimirConfig}"
    "LOKI_MCP_CONTEXT=${mcpContext}"
  ];

  restartTriggers = [
    grafanaDatasources
    lokiConfig
    tempoConfig
    mimirConfig
    mcpContext
  ];
in
  podman.mkService {
    inherit stackName;
    description = "LGTM (Loki/Grafana/Tempo/Mimir) Podman Compose Stack";
    projectName = "loki";
    inherit composeFile envFiles preStart stackHosts firewallPorts extraEnv restartTriggers;
  }
