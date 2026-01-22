{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "caddy-tailscale-stack";
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;

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
      "/run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/podman unshare chown -R 0:0 ${dataRoot}/tailscale/ts-state ${dataRoot}/tailscale/caddy_data ${dataRoot}/tailscale/caddy_config"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
