{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "audiobookshelf-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "audiobookshelf-docker-compose.yml";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};

  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Audiobookshelf Podman Compose Stack";
    projectName = "audiobookshelf";
    inherit composeFile;
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
  }
