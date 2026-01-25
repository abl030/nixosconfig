{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "invoices-stack";
  inherit (config.homelab.containers) dataRoot;

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
    extraEnv = ["CADDY_FILE=${caddyFile}"];
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/invoices/caddy_data ${dataRoot}/invoices/caddy_config ${dataRoot}/invoices/ts-state ${dataRoot}/invoices/postgres/data ${dataRoot}/invoices/solr/data ${dataRoot}/invoices/docspell/inbox ${dataRoot}/invoices/firefly/postgres/data ${dataRoot}/invoices/firefly/app_uploads"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/invoices/caddy_data ${dataRoot}/invoices/caddy_config ${dataRoot}/invoices/ts-state ${dataRoot}/invoices/postgres ${dataRoot}/invoices/solr ${dataRoot}/invoices/docspell ${dataRoot}/invoices/firefly"
    ];
    wants = dependsOn;
    after = dependsOn;
  }
