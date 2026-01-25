{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "tdarr-igp-stack";
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;
  userGroup = config.users.users.${user}.group or "users";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "tdarr-igp-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "tdarr-igp.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount" "mnt-fuse.mount"];
in
  lib.mkMerge [
    {
      systemd.tmpfiles.rules = lib.mkAfter [
        "d ${dataRoot}/tdarr 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/tdarr/configs 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/tdarr/logs 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/tdarr/temp 0750 ${user} ${userGroup} -"
      ];
    }
    (podman.mkService {
      inherit stackName;
      description = "Tdarr (IGP) Podman Compose Stack";
      projectName = "tdarr-igp";
      inherit composeFile;
      inherit envFiles;
      preStart = [
        "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tdarr/configs ${dataRoot}/tdarr/logs ${dataRoot}/tdarr/temp"
      ];
      requiresMounts = ["/mnt/data" "/mnt/fuse"];
      wants = dependsOn;
      after = dependsOn;
      firewallPorts = [8265];
      reloadTriggers = ["management-stack.service"];
    })
  ]
