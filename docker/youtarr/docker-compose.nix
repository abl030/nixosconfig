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
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Youtarr Podman Compose Stack";
    projectName = "youtarr";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/youtarr/config ${dataRoot}/youtarr/images ${dataRoot}/youtarr/jobs ${dataRoot}/youtarr/database"
      # Use root chown for existing data (podman unshare fails on data owned by different UIDs)
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/youtarr"
    ];
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
  }
