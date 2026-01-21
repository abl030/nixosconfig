{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "tdarr-igp-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "tdarr-igp-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "tdarr-igp.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../../lib/podman-compose.nix {inherit config lib pkgs;};
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
    description = "Tdarr (IGP) Podman Compose Stack";
    projectName = "tdarr-igp";
    inherit composeFile;
    inherit envFiles;
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
  }
