{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "management-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "management-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "management.env";
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
    description = "Management Podman Compose Stack";
    projectName = "management";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "dozzle.ablz.au";
        port = 8082;
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8082 8050];
  }
