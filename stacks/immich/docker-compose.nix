{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "immich-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "immich-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "immich-Caddyfile";
  };
  tailscaleJson = builtins.path {
    path = ./immich-tailscale-serve.json;
    name = "immich-tailscale-serve.json";
  };

  encEnv = config.homelab.secrets.sopsFile "immich.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
in
  podman.mkService {
    inherit stackName;
    description = "Immich Podman Compose Stack";
    projectName = "immich";
    inherit composeFile;
    inherit envFiles;
    restartTriggers = [
      caddyFile
      tailscaleJson
    ];
    extraEnv = [
      "CADDY_FILE=${caddyFile}"
      "TAILSCALE_JSON=${tailscaleJson}"
    ];
    stackHosts = [
      {
        host = "photos.ablz.au";
        port = 2283;
        websocket = true;
        maxBodySize = "0";
      }
    ];
    stackMonitors = [
      {
        name = "Immich";
        url = "https://photos.ablz.au/api/server/ping";
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8081]; # Prometheus metrics
    scrapeTargets = [
      {
        job = "immich";
        address = "localhost:8081";
      }
    ];
  }
