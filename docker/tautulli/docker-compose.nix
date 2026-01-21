{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "tautulli-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "tautulli-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "tautulli.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount" "mnt-fuse.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Tautulli Podman Compose Stack";
    projectName = "tautulli";
    inherit composeFile;
    inherit envFiles;
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
  }
