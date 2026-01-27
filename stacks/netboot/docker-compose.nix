{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "netboot-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "netboot-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "netboot.env";
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
    description = "Netboot Podman Compose Stack";
    projectName = "netboot";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "netboot.ablz.au";
        port = 3000;
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [3000 8080];
    firewallUDPPorts = [1069];
  }
