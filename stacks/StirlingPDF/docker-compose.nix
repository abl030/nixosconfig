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
in
  podman.mkService {
    inherit stackName;
    description = "StirlingPDF Podman Compose Stack";
    projectName = "stirlingpdf";
    inherit composeFile;
    stackHosts = [
      {
        host = "pdf.ablz.au";
        port = 8083;
      }
    ];
    stackMonitors = [
      {
        name = "StirlingPDF";
        url = "https://pdf.ablz.au/";
      }
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [];
  }
