{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "music-stack";
  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "music-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "music-Caddyfile";
  };
  # Kept for ombi-db's INIT_SQL and as restart trigger if re-enabled
  initSql = builtins.path {
    path = ./init.sql;
    name = "music-init.sql";
  };

  encEnv = config.homelab.secrets.sopsFile "music.env";
  encAcmeEnv = config.homelab.secrets.sopsFile "acme-cloudflare.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";
  runAcmeEnv = "/run/user/%U/secrets/${stackName}-acme.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};

  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
    {
      sopsFile = encAcmeEnv;
      runFile = runAcmeEnv;
    }
  ];

  # Ombi disabled — crash-looping with coredumps.
  # database.json generation moved into container entrypoint to avoid
  # preStart race condition with sops secrets. See docker-compose.yml.
  preStart = [];

  dependsOn = [
    "network-online.target"
    "fuse-mergerfs-music-rw.service"
  ];
in
  podman.mkService {
    inherit stackName;
    description = "Music Podman Compose Stack";
    projectName = "music";
    inherit composeFile;
    inherit envFiles;
    restartTriggers = [
      caddyFile
      initSql
    ];
    extraEnv = [
      "CADDY_FILE=${caddyFile}"
      "INIT_SQL=${initSql}"
    ];
    inherit preStart;
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8686 8085 5030 5031];
  }
