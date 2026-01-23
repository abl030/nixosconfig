{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "caddy-tailscale-stack";
  inherit (config.homelab.containers) dataRoot;

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "caddy-tailscale-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "caddy-tailscale-Caddyfile";
  };

  encEnv = config.homelab.secrets.sopsFile "caddy-tailscale.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
in
  podman.mkService {
    inherit stackName;
    description = "Caddy Tailscale Podman Compose Stack";
    projectName = "caddy";
    inherit composeFile;
    inherit envFiles;
    extraEnv = ["CADDY_FILE=${caddyFile}"];
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tailscale/ts-state ${dataRoot}/tailscale/caddy_data ${dataRoot}/tailscale/caddy_config"
      # Use root chown for existing data (root-owned from old Docker)
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/tailscale/ts-state ${dataRoot}/tailscale/caddy_data ${dataRoot}/tailscale/caddy_config"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
