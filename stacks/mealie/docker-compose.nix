{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "mealie-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "mealie-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "mealie.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount"];
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Mealie Podman Compose Stack";
    projectName = "mealie";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/mealie/data ${dataRoot}/mealie/pgdata"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/mealie"
    ];
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
  }
