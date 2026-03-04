# Inotify bridge receiver — music-only subset.
#
# Listens for UDP datagrams from the Unraid inotify sender and creates
# `refresh` marker files via a bindfs FUSE mount so that Lidarr's
# filesystem watcher picks up new music over NFS.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.inotify-receiver;

  # Music-only receiver script (subset of stacks/jellyfinn/inotify-recv.sh)
  recvScript = pkgs.writeShellScript "inotify-recv.sh" ''
    export PATH="${lib.makeBinPath [pkgs.coreutils pkgs.gawk]}:$PATH"
    set -eu
    MUSIC_DIR="${cfg.musicDir}"
    MARKER_NAME="refresh"
    TTL=46

    log() { printf '%s\n' "$*"; }

    payload="$(cat | tr -d '\r\n')"
    log "[receiver] recv: ''${payload:-<empty>}"

    # Accept only /data/music/*
    case "$payload" in
      /data/music/*) ;;
      *) log "[receiver] reject (not music): $payload"; exit 0 ;;
    esac

    # Map /data/music/... to configured musicDir
    relative="''${payload#/data/music}"
    relative="''${relative#/}"
    target="$MUSIC_DIR/$relative"

    # Resolve to directory
    [ -d "$target" ] || target="$(dirname -- "$target" 2>/dev/null || echo "$target")"
    # Strip trailing slash
    case "$target" in */) target="''${target%/}" ;; esac

    tickle() {
      t="$1"
      [ -z "$t" ] && return 0
      [ -d "$t" ] && [ -w "$t" ] || { log "[receiver] not writable: $t"; return 0; }

      key="$(printf '%s' "$t" | md5sum | awk '{print $1}')"
      lock="/tmp/refresh-$key.lock"

      if mkdir "$lock" 2>/dev/null; then
        marker="$t/$MARKER_NAME"
        if : >"$marker" 2>/dev/null; then
          log "[receiver] refresh touched: $marker (delete in ''${TTL}s)"
          ( sleep "$TTL"; rm -f "$marker"; rmdir "$lock" 2>/dev/null || true
            log "[receiver] refresh removed: $marker" ) &
        else
          log "[receiver] create failed: $marker"
          rmdir "$lock" 2>/dev/null || true
        fi
      else
        log "[receiver] refresh already pending for $t"
      fi
    }

    # Tickle the target directory
    tickle "$target"

    # Also tickle the top-level artist folder (helps Lidarr discover new artists/albums)
    relative_from_root="''${target#$MUSIC_DIR}"
    relative_from_root="''${relative_from_root#/}"
    artist="''${relative_from_root%%/*}"
    if [ -n "$artist" ] && [ "$MUSIC_DIR/$artist" != "$target" ]; then
      tickle "$MUSIC_DIR/$artist"
    fi
  '';

  # Entrypoint: socat listener + healthcheck heartbeat
  entrypoint = pkgs.writeShellScript "inotify-receiver-entrypoint.sh" ''
    set -e
    HEALTH_FILE="/tmp/receiver-healthy"
    : >"$HEALTH_FILE"

    echo "[receiver] listening UDP 0.0.0.0:${toString cfg.port}"
    echo "[receiver] music dir: ${cfg.musicDir}"

    ${pkgs.socat}/bin/socat -u UDP4-RECVFROM:${toString cfg.port},bind=0.0.0.0,fork \
      EXEC:${recvScript},fdin=0 &
    SOCAT_PID=$!

    # Heartbeat loop
    (
      while sleep 30; do
        if kill -0 "$SOCAT_PID" 2>/dev/null; then
          date +%s >"$HEALTH_FILE" || true
        else
          exit 0
        fi
      done
    ) &

    wait "$SOCAT_PID"
  '';
in {
  options.homelab.services.inotify-receiver = {
    enable = lib.mkEnableOption "inotify bridge receiver for music (UDP)";

    musicDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/fuse/Media/Music";
      description = "Local path to write refresh markers into (should be a bindfs FUSE mount).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9999;
      description = "UDP port to listen on.";
    };

    allowFrom = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.2";
      description = "IP address allowed to send datagrams (Unraid).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.inotify-receiver = {
      description = "Inotify bridge receiver (music, UDP)";
      after = ["network.target" "bindfs-music.service"];
      requires = ["bindfs-music.service"];
      wantedBy = ["multi-user.target"];

      path = [pkgs.coreutils];

      serviceConfig = {
        ExecStart = entrypoint;
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening
        DynamicUser = true;
        SupplementaryGroups = ["users"];
        ProtectSystem = "strict";
        ReadWritePaths = [cfg.musicDir "/tmp"];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
      };
    };

    # Allow UDP from Unraid only
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p udp --dport ${toString cfg.port} -s ${cfg.allowFrom} -j nixos-fw-accept
    '';
  };
}
