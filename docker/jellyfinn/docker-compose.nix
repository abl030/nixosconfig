{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "jellyfin-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "jellyfin-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "jellyfin-Caddyfile";
  };

  encEnv = config.homelab.secrets.sopsFile "jellyfin.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target" "mnt-data.mount" "mnt-fuse.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "Jellyfin Podman Compose Stack";
    projectName = "jellyfin";
    inherit composeFile;
    inherit envFiles;
    extraEnv = ["CADDY_FILE=${caddyFile}"];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
  }
