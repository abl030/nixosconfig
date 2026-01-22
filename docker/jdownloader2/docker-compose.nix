{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "jdownloader2-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "jdownloader2-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "jdownloader2.env";
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
    description = "JDownloader2 Podman Compose Stack";
    projectName = "jdownloader2";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/jdownloader2"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/jdownloader2"
    ];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [5800];
  }
