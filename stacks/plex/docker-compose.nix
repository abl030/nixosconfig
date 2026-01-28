{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "plex-stack";
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;
  userGroup = config.users.users.${user}.group or "users";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "plex-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "plex.env";
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
  {
    systemd.tmpfiles.rules = lib.mkAfter [
      "d ${dataRoot}/plex 0750 ${user} ${userGroup} -"
    ];
  }
  // podman.mkService {
    inherit stackName;
    description = "Plex Podman Compose Stack";
    projectName = "plex";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "plex2.ablz.au";
        port = 32400;
      }
    ];
    stackMonitors = [
      {
        name = "Plex";
        url = "https://plex2.ablz.au/";
      }
    ];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [];
  }
