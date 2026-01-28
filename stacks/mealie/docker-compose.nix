{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "mealie-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "mealie-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "mealie.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Mealie Podman Compose Stack";
    projectName = "mealie";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "cooking.ablz.au";
        port = 9925;
      }
    ];
    stackMonitors = [
      {
        name = "Mealie";
        url = "https://cooking.ablz.au/";
      }
    ];
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [];
  }
