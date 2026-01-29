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
  inotifyEntrypoint = pkgs.writeTextFile {
    name = "inotify-entrypoint.sh";
    executable = true;
    text = ''
      #!/bin/sh
      set -e

      # Resolve defaults at runtime (avoid compose pre-substitution)
      HEALTH_FILE="''${HEALTH_FILE:-/tmp/receiver-healthy}"
      [ -n "$HEALTH_FILE" ] || HEALTH_FILE=/tmp/receiver-healthy
      mkdir -p "$(dirname "$HEALTH_FILE")"
      : >"$HEALTH_FILE" || { echo "[receiver] cannot write $HEALTH_FILE"; exit 1; }

      ROOT_MOVIES="''${ROOT_MOVIES:-/data/movies}"
      ROOT_TV="''${ROOT_TV:-/data/tv}"
      ROOT_MUSIC="''${ROOT_MUSIC:-/data/music}"

      echo "[receiver] listening UDP 0.0.0.0:9999"
      echo "[receiver] guards: movies=$ROOT_MOVIES tv=$ROOT_TV music=$ROOT_MUSIC"
      echo "[receiver] healthfile: $HEALTH_FILE (interval=''${HEALTH_INTERVAL:-30}s window=''${HEALTH_WINDOW:-180}s)"

      # Start socat (fork spawns per datagram). If it dies, container exits.
      # Use EXEC instead of SYSTEM to avoid shell interpretation issues.
      socat -u UDP4-RECVFROM:9999,bind=0.0.0.0,fork EXEC:/usr/local/bin/inotify-recv.sh,fdin=0 &
      SOCAT_PID=$!

      # Heartbeat loop: update only if socat is alive.
      (
        while sleep "''${HEALTH_INTERVAL:-30}"; do
          if kill -0 "$SOCAT_PID" 2>/dev/null; then
            date +%s >"$HEALTH_FILE" || true
          else
            exit 0
          fi
        done
      ) &

      # Reap socat (main process exits if socat dies).
      wait "$SOCAT_PID"
    '';
  };

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
      composeArgs = "--in-pod false";
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
          name = "Jellyfinn-local";
          url = "https://jelly.ablz.au/System/Info/Public";
        }
      ];
      extraEnv = [
        "CADDY_FILE=${caddyFile}"
        "INOTIFY_SCRIPT=${inotifyScript}"
        "INOTIFY_ENTRYPOINT=${inotifyEntrypoint}"
        "PODMAN_COMPOSE_IN_POD=false"
      ];
      requiresMounts = [
        "/mnt/data"
        "/mnt/fuse/Media/Movies"
        "/mnt/fuse/Media/TV_Shows"
        "/mnt/fuse/Media/Music"
      ];
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
