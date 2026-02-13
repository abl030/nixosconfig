{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "restart-probe-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "restart-probe-docker-compose.yml";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
in
  podman.mkService {
    inherit stackName;
    description = "Restart Probe Podman Compose Stack";
    projectName = "restart-probe";
    inherit composeFile;
    extraEnv = [
      "PROBE_VERSION=v1"
    ];
  }
