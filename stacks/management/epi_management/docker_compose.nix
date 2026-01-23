{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "epi-management-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "epi-management-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "epi-management.env";
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
  podman.mkService {
    inherit stackName;
    description = "EPI Management Podman Compose Stack";
    projectName = "epi_management";
    inherit composeFile;
    inherit envFiles;
    wants = dependsOn;
    after = dependsOn;
  }
