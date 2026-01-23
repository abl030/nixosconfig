{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "atuin-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "atuin-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "atuin.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Atuin Podman Compose Stack";
    projectName = "atuin";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/atuin/config ${dataRoot}/atuin/database"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/atuin"
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8888];
  }
