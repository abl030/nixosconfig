{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "paperless-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "paperless-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "paperless.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  inherit (config.homelab.containers) dataRoot;
  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Paperless Podman Compose Stack";
    projectName = "paperless";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/paperless/pgdata ${dataRoot}/paperless/data ${dataRoot}/paperlessgpt/prompts"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/paperless ${dataRoot}/paperlessgpt"
    ];
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
  }
