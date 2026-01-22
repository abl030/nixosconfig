{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "tautulli-stack";
  inherit (config.homelab) user;

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
  podmanBin = "${pkgs.podman}/bin/podman";
in
  podman.mkService {
    inherit stackName;
    description = "Tautulli Podman Compose Stack";
    projectName = "tautulli";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tautulli"
      ''/run/current-system/sw/bin/runuser -u ${user} -- ${podmanBin} unshare chown -R 1000:1000 ${dataRoot}/tautulli''
    ];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
  }
