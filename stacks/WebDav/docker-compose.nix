{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "webdav-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "webdav-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "webdav.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "WebDav Podman Compose Stack";
    projectName = "webdav";
    inherit composeFile;
    inherit envFiles;
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [9090];
  }
