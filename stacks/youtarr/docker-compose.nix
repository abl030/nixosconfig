{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "youtarr-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "youtarr-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "youtarr.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Youtarr Podman Compose Stack";
    projectName = "youtarr";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "youtarr.ablz.au";
        port = 3087;
      }
    ];
    stackMonitors = [
      {
        name = "Youtarr";
        url = "https://youtarr.ablz.au/";
      }
    ];
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
  }
