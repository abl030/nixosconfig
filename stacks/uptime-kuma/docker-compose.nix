{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "uptime-kuma-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "uptime-kuma-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "uptime-kuma.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Uptime Kuma Podman Compose Stack";
    projectName = "uptime-kuma";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/uptime-kuma"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/uptime-kuma"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
