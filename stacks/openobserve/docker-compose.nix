{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "openobserve-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "openobserve-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "openobserve.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];
in
  podman.mkService {
    inherit stackName;
    description = "OpenObserve Podman Compose Stack";
    projectName = "openobserve";
    inherit composeFile envFiles;

    stackHosts = [
      {
        host = "logs.ablz.au";
        port = 5080;
      }
    ];

    stackMonitors = [
      {
        name = "OpenObserve";
        url = "https://logs.ablz.au/";
      }
    ];
  }
