{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "immich-stack";
  inherit (config.homelab.containers) dataRoot;

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "immich-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "immich-Caddyfile";
  };
  tailscaleJson = builtins.path {
    path = ./immich-tailscale-serve.json;
    name = "immich-tailscale-serve.json";
  };

  encEnv = config.homelab.secrets.sopsFile "immich.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
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
    description = "Immich Podman Compose Stack";
    projectName = "immich";
    inherit composeFile;
    inherit envFiles;
    extraEnv = [
      "CADDY_FILE=${caddyFile}"
      "TAILSCALE_JSON=${tailscaleJson}"
    ];
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tailscale/immich ${dataRoot}/tailscale/immich/caddy_data ${dataRoot}/tailscale/immich/caddy_config ${dataRoot}/AI/immich ${dataRoot}/immichPG"
      # Use root chown for existing data (postgres was uid 999 under Docker)
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/tailscale/immich ${dataRoot}/AI/immich ${dataRoot}/immichPG"
    ];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [2283];
  }
