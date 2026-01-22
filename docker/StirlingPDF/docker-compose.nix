{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "stirlingpdf-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "stirlingpdf-docker-compose.yml";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  dependsOn = ["network-online.target"];
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "StirlingPDF Podman Compose Stack";
    projectName = "stirlingpdf";
    inherit composeFile;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/StirlingPDF/trainingData ${dataRoot}/StirlingPDF/extraConfigs ${dataRoot}/StirlingPDF/customFiles ${dataRoot}/StirlingPDF/logs ${dataRoot}/StirlingPDF/pipeline"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/StirlingPDF"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
