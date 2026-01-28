{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "uptime-kuma-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "uptime-kuma-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "uptime-kuma.env";
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
    description = "Uptime Kuma Podman Compose Stack";
    projectName = "uptime-kuma";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "status.ablz.au";
        port = 3001;
        websocket = true;
      }
    ];
    stackMonitors = [
      {
        name = "Uptime Kuma";
        url = "https://status.ablz.au/";
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [];
  }
