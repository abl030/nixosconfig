{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "immich-stack";
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;

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
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/tailscale/immich ${dataRoot}/tailscale/immich/caddy_data ${dataRoot}/tailscale/immich/caddy_config"
      "/run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/podman unshare chown -R 0:0 ${dataRoot}/tailscale/immich"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
