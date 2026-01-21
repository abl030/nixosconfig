{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "caddy-tailscale-stack";

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
    wants = dependsOn;
    after = dependsOn;
  }
