{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "tautulli-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "tautulli-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "tautulli.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount" "mnt-fuse.mount"];
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Tautulli Podman Compose Stack";
    projectName = "tautulli";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tautulli"
      # Use root chown for existing data (podman unshare fails on data owned by different UIDs)
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/tautulli"
    ];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8181];
  }
