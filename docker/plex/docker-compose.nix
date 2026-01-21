{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "plex-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "plex-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "plex.env";
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
    description = "Plex Podman Compose Stack";
    projectName = "plex";
    inherit composeFile;
    inherit envFiles;
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
  }
