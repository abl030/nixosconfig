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
    extraEnv = [
      "CADDY_FILE=${caddyFile}"
      "INOTIFY_SCRIPT=${inotifyScript}" # <--- Add this line
    ];
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/jellyfin/jellyfin ${dataRoot}/jellyfin/tailscale ${dataRoot}/jellyfin/caddy/data ${dataRoot}/jellyfin/caddy/config ${dataRoot}/jellyfin/watchstate ${dataRoot}/jellyfin/jellystat/postgres-data ${dataRoot}/jellyfin/jellystat/backup-data"
      "/run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/podman unshare chown -R 0:0 ${dataRoot}/jellyfin"
    ];
    requiresMounts = ["/mnt/data" "/mnt/fuse"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8096];
  })
  {
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p udp -s 192.168.1.2 --dport 9999 -j nixos-fw-accept
    '';
  }
]
