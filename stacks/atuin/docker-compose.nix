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
in
  podman.mkService {
    inherit stackName;
    description = "Atuin Podman Compose Stack";
    projectName = "atuin";
    inherit composeFile;
    inherit envFiles;
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8888];
  }
