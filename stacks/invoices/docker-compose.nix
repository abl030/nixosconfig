{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "invoices-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "invoices-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "invoices-Caddyfile";
  };

  encEnv = config.homelab.secrets.sopsFile "invoices.env";
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
    description = "Invoices Podman Compose Stack";
    projectName = "invoices";
    inherit composeFile;
    inherit envFiles;
    restartTriggers = [caddyFile];
    extraEnv = ["CADDY_FILE=${caddyFile}"];
    wants = dependsOn;
    after = dependsOn;
  }
