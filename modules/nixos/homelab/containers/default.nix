{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.containers;
  inherit (config.homelab) user userHome;
  # UID may be dynamically assigned; fall back to 1000 if unset/null.
  userUid = let
    uid = config.users.users.${user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;
  podmanBin = "${pkgs.podman}/bin/podman";
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;
  autoUpdateScript = pkgs.writeShellScript "podman-auto-update" ''
    set -euo pipefail
    log_file="$(/run/current-system/sw/bin/mktemp)"
    if ${podmanBin} auto-update >"$log_file" 2>&1; then
      /run/current-system/sw/bin/cat "$log_file"
      /run/current-system/sw/bin/rm -f "$log_file"
      exit 0
    fi
    status=$?
    /run/current-system/sw/bin/cat "$log_file" >&2
    message_tail="$(/run/current-system/sw/bin/tail -n 80 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
    /run/current-system/sw/bin/rm -f "$log_file"
    token_file="''${GOTIFY_TOKEN_FILE:-/run/secrets/gotify/token}"
    if [[ -r "$token_file" ]]; then
      token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
      if [[ -n "$token" ]]; then
        /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
          -F "title=podman auto-update failed on ${config.networking.hostName}" \
          -F "message=$message_tail" \
          -F "priority=8" >/dev/null || true
      fi
    fi
    exit "$status"
  '';
  podmanServiceScript = pkgs.writeShellScript "podman-system-service" ''
    set -euo pipefail
    exec ${podmanBin} system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock"
  '';
  storageConf = pkgs.writeTextFile {
    name = "containers-storage.conf";
    text = ''
      [storage]
      driver = "overlay"
      graphroot = "${cfg.dataRoot}/containers"
      runroot = "/run/user/${toString userUid}/containers"

      [storage.options]
      mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
    '';
  };
in {
  options.homelab.containers = {
    enable = lib.mkEnableOption "Rootless Podman stack management";

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/docker";
      description = "Root directory for container persistent data.";
    };

    autoUpdate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Podman auto-update via systemd user timer";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Systemd OnCalendar schedule for podman auto-update.";
      };
    };

    cleanup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Prune stopped rootless podman containers/pods";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Systemd OnCalendar schedule for podman prune.";
      };

      maxAge = lib.mkOption {
        type = lib.types.str;
        default = "4h";
        description = "Only prune stopped containers older than this duration (podman filter until=...).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    security.unprivilegedUsernsClone = true;
    security.wrappers = {
      newuidmap = {
        source = "${pkgs.shadow}/bin/newuidmap";
        owner = "root";
        group = "root";
        setuid = true;
      };
      newgidmap = {
        source = "${pkgs.shadow}/bin/newgidmap";
        owner = "root";
        group = "root";
        setuid = true;
      };
    };

    users.users.${user} = {
      linger = true;
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };

    environment = {
      systemPackages = lib.mkOrder 1600 (with pkgs; [
        podman
        podman-compose
        buildah
        skopeo
        shadow
        fuse-overlayfs
        slirp4netns
        netavark
        aardvark-dns
      ]);

      # Override upstream containers.nix storage.conf to ensure rootless graphroot/runroot.
      etc."containers/storage.conf".source = lib.mkForce storageConf;

      sessionVariables = {
        DOCKER_HOST = lib.mkDefault "unix:///run/user/${toString userUid}/podman/podman.sock";
      };
    };

    systemd.tmpfiles.rules = lib.mkAfter [
      "d ${cfg.dataRoot} 0750 ${user} ${user} -"
      "d ${cfg.dataRoot}/containers 0750 ${user} ${user} -"
    ];

    systemd = {
      services = {
        podman-system-service = {
          description = "Rootless Podman API service";
          # Wait for user@1000.service which creates /run/user/1000
          after = ["user@${toString userUid}.service"];
          requires = ["user@${toString userUid}.service"];
          serviceConfig = {
            Type = "simple";
            ExecStartPre = "/run/current-system/sw/bin/mkdir -p /run/user/${toString userUid}/podman";
            ExecStart = podmanServiceScript;
            Restart = "on-failure";
            RestartSec = "10s";
            User = user;
            Environment = [
              "HOME=${userHome}"
              "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
              "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
            ];
          };
          wantedBy = ["multi-user.target"];
        };

        podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
          description = "Podman auto-update (rootless)";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = autoUpdateScript;
            User = user;
            Environment =
              [
                "HOME=${userHome}"
                "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
                "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
              ]
              ++ lib.optional (gotifyTokenFile != null) "GOTIFY_TOKEN_FILE=${gotifyTokenFile}";
          };
        };

        podman-rootless-prune = lib.mkIf cfg.cleanup.enable {
          description = "Podman prune (rootless) for stopped containers/pods";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "podman-rootless-prune" ''
              set -euo pipefail
              ${podmanBin} container prune -f --filter "until=${cfg.cleanup.maxAge}"
              ${podmanBin} pod prune -f

              # Clean up orphaned health check timers for containers that no longer exist
              active_ids=$(${podmanBin} ps -q 2>/dev/null | tr '\n' '|')
              active_ids="''${active_ids%|}"
              if [ -z "$active_ids" ]; then
                active_ids="NONE"
              fi
              /run/current-system/sw/bin/systemctl --user list-units --plain --no-legend --type=timer \
                | /run/current-system/sw/bin/grep -E '^[0-9a-f]{64}-' \
                | /run/current-system/sw/bin/awk '{print $1}' \
                | while read -r timer; do
                    cid="''${timer%%-*}"
                    if ! echo "$cid" | /run/current-system/sw/bin/grep -qE "^($active_ids)"; then
                      /run/current-system/sw/bin/systemctl --user stop "$timer" 2>/dev/null || true
                    fi
                  done
              /run/current-system/sw/bin/systemctl --user reset-failed 2>/dev/null || true
            '';
            User = user;
            Environment = [
              "HOME=${userHome}"
              "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
              "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
            ];
          };
        };
      };

      timers = {
        podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
          description = "Podman auto-update timer (rootless)";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.autoUpdate.schedule;
            Persistent = true;
          };
        };

        podman-rootless-prune = lib.mkIf cfg.cleanup.enable {
          description = "Podman prune timer (rootless)";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.cleanup.schedule;
            Persistent = true;
          };
        };
      };
    };
  };
}
