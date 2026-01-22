{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "igpu-management-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "igpu-management-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "igpu-management.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
in
  {
    networking.firewall.allowedTCPPorts = [7007];
  }
  // podman.mkService {
    inherit stackName;
    description = "IGPU Management Podman Compose Stack";
    projectName = "igpu";
    inherit composeFile;
    inherit envFiles;
    wants = dependsOn;
    after = dependsOn;
  }
