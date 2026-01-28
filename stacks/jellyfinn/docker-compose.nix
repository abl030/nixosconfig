{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "jellyfin-stack";
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;
  userGroup = config.users.users.${user}.group or "users";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "jellyfin-docker-compose.yml";
  };
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "jellyfin-Caddyfile";
  };

  inotifyScript = pkgs.writeScript "inotify-recv.sh" (builtins.readFile ./inotify-recv.sh);

  encEnv = config.homelab.secrets.sopsFile "jellyfin.env";
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
  lib.mkMerge [
    {
      systemd.tmpfiles.rules = lib.mkAfter [
        "d ${dataRoot}/jellyfin 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/jellyfin 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/tailscale 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/caddy 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/caddy/data 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/caddy/config 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/watchstate 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/jellystat 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/jellystat/postgres-data 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/jellyfin/jellystat/backup-data 0750 ${user} ${userGroup} -"
      ];
    }
    (podman.mkService {
      inherit stackName;
      description = "Jellyfin Podman Compose Stack";
      projectName = "jellyfin";
      inherit composeFile;
      inherit envFiles;
      stackHosts = [
        {
          host = "jelly.ablz.au";
          port = 8096;
        }
      ];
      stackMonitors = [
        {
          name = "Jellyfin";
          url = "https://jelly.ablz.au/";
        }
      ];
      extraEnv = [
        "CADDY_FILE=${caddyFile}"
        "INOTIFY_SCRIPT=${inotifyScript}"
      ];
      requiresMounts = ["/mnt/data" "/mnt/fuse"];
      wants = dependsOn;
      after = dependsOn;
      firewallPorts = [];
    })
    {
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p udp -s 192.168.1.2 --dport 9999 -j nixos-fw-accept
      '';
    }
  ]
