{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "restart-probe-b-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "restart-probe-b-docker-compose.yml";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
in
  podman.mkService {
    inherit stackName;
    description = "Restart Probe B Podman Compose Stack";
    projectName = "restart-probe-b";
    inherit composeFile;
    extraEnv = [
      "PROBE_VERSION=v3"
    ];
  }
