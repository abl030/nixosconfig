{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "smokeping-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "smokeping-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "smokeping.env";
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
    description = "Smokeping Podman Compose Stack";
    projectName = "smokeping";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "ping.ablz.au";
        port = 8084;
      }
    ];
    stackMonitors = [
      {
        name = "Smokeping";
        url = "https://ping.ablz.au";
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8084];
  }
