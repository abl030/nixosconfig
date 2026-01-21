{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "kopia-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "kopia-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "kopia.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = [
    "network-online.target"
    "mnt-data.mount"
    "mnt-mum.automount"
  ];
in
  podman.mkService {
    inherit stackName;
    description = "Kopia Podman Compose Stack";
    projectName = "kopia";
    inherit composeFile;
    inherit envFiles;
    requiresMounts = ["/mnt/data" "/mnt/mum"];
    wants = dependsOn;
    after = dependsOn;
  }
