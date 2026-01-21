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
  dbTemplate = builtins.path {
    path = ./database.json.template;
    name = "music-database.json.template";
  };
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

  inherit (config.homelab.containers) dataRoot;
  gettextBin = "${pkgs.gettext}/bin/envsubst";
  podmanBin = "${pkgs.podman}/bin/podman";

  preStart = [
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/ombi/config"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/ombi/db"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/music/lidarr"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/music/filebrowser"
    "/run/current-system/sw/bin/mkdir -p ${dataRoot}/music"

    (pkgs.writeShellScript "generate-ombi-json" ''
      set -a
      source "$XDG_RUNTIME_DIR/secrets/${stackName}.env"
      set +a
      ${gettextBin} < ${dbTemplate} > ${dataRoot}/ombi/config/database.json
    '')

    ''${podmanBin} unshare chown -R 99:100 ${dataRoot}/ombi/config''
    ''${podmanBin} unshare chown -R 99:100 ${dataRoot}/music/lidarr''
    ''${podmanBin} unshare chown -R 99:100 ${dataRoot}/music/filebrowser''
  ];

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
    extraEnv = [
      "CADDY_FILE=${caddyFile}"
      "INIT_SQL=${initSql}"
    ];
    inherit preStart;
    wants = dependsOn;
    after = dependsOn;
  }
