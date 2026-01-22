{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "netboot-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "netboot-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "netboot.env";
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
    description = "Netboot Podman Compose Stack";
    projectName = "netboot";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/netboot/config ${dataRoot}/netboot/assets"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/netboot"
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [3000];
  }
