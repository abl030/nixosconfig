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

  inherit (config.homelab.containers) dataRoot;
  dependsOn = ["network-online.target"];
in
  podman.mkService {
    inherit stackName;
    description = "Management Podman Compose Stack";
    projectName = "management";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/dozzle/data ${dataRoot}/gotify/data"
      # Use root chown for existing data
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/dozzle/data ${dataRoot}/gotify/data"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
