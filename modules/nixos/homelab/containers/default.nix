{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.containers;
  inherit (config.homelab) user userHome;
  stackUnits = lib.unique cfg.stackUnits;
  stackUnitConfigFiles = map (unit: "systemd/user/${unit}") stackUnits;
  stackUnitForceAttrs = lib.genAttrs stackUnitConfigFiles (_: {force = true;});
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
  notifyGotify = ''
    local title="$1" msg="$2"
    local token_file="''${GOTIFY_TOKEN_FILE:-/run/secrets/gotify/token}"
    if [[ -r "$token_file" ]]; then
      local token
      token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
      if [[ -n "$token" ]]; then
        /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
          -F "title=$title" \
          -F "message=$msg" \
          -F "priority=8" >/dev/null || true
      fi
    fi
  '';
  autoUpdateScript = pkgs.writeShellScript "podman-auto-update" ''
    set -euo pipefail

    notify() {
      ${notifyGotify}
    }

    log_file="$(/run/current-system/sw/bin/mktemp)"

    # Run the auto-update
    if auto_update_output="$(${podmanBin} auto-update 2>&1)"; then
      :
    else
      status=$?
      printf "%s\n" "$auto_update_output" | /run/current-system/sw/bin/tee "$log_file" >&2
      message_tail="$(/run/current-system/sw/bin/tail -n 80 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
      /run/current-system/sw/bin/rm -f "$log_file"
      notify "podman auto-update failed on ${config.networking.hostName}" "$message_tail"
      exit "$status"
    fi

    printf "%s\n" "$auto_update_output" >"$log_file"

    if printf "%s\n" "$auto_update_output" | /run/current-system/sw/bin/grep -qiE '(error:|errors occurred:)'; then
      /run/current-system/sw/bin/cat "$log_file" >&2
      message_tail="$(/run/current-system/sw/bin/tail -n 80 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
      /run/current-system/sw/bin/rm -f "$log_file"
      notify "podman auto-update reported errors on ${config.networking.hostName}" "$message_tail"
      exit 1
    fi

    /run/current-system/sw/bin/cat "$log_file"

    # Extract containers that were updated (UPDATED=true in output)
    updated_names=$(/run/current-system/sw/bin/awk '$NF == "true" {print $3}' "$log_file" | /run/current-system/sw/bin/tr -d '()')
    /run/current-system/sw/bin/rm -f "$log_file"

    if [[ -z "$updated_names" ]]; then
      exit 0
    fi

    # Wait for containers to settle after update
    sleep 30

    # Check for two failure modes:
    # 1. Container crashed and is not running
    # 2. Container was rolled back (still running on old image)
    #    Detected by --dry-run showing it still needs an update
    failed=""

    for name in $updated_names; do
      state=$(${podmanBin} inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
      if [[ "$state" != "running" ]]; then
        failed="$failed\n  $name: not running ($state)"
      fi
    done

    # Dry-run to detect rollbacks — containers that still show as needing update
    dry_run_file="$(/run/current-system/sw/bin/mktemp)"
    if dry_run_output="$(${podmanBin} auto-update --dry-run 2>&1)"; then
      printf "%s\n" "$dry_run_output" >"$dry_run_file"
    else
      status=$?
      printf "%s\n" "$dry_run_output" | /run/current-system/sw/bin/tee "$dry_run_file" >&2
      message_tail="$(/run/current-system/sw/bin/tail -n 80 "$dry_run_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
      /run/current-system/sw/bin/rm -f "$dry_run_file"
      notify "podman auto-update dry-run failed on ${config.networking.hostName}" "$message_tail"
      exit "$status"
    fi

    if /run/current-system/sw/bin/grep -qiE '(error:|errors occurred:)' "$dry_run_file"; then
      /run/current-system/sw/bin/cat "$dry_run_file" >&2
      message_tail="$(/run/current-system/sw/bin/tail -n 80 "$dry_run_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
      /run/current-system/sw/bin/rm -f "$dry_run_file"
      notify "podman auto-update dry-run reported errors on ${config.networking.hostName}" "$message_tail"
      exit 1
    fi

    rolled_back=$(/run/current-system/sw/bin/awk '$NF == "pending" {print $3}' "$dry_run_file" | /run/current-system/sw/bin/tr -d '()')
    /run/current-system/sw/bin/rm -f "$dry_run_file"

    for name in $rolled_back; do
      # Only report if this container was in our updated list
      for updated in $updated_names; do
        if [[ "$name" == "$updated" ]]; then
          failed="$failed\n  $name: rolled back (update failed health check)"
          break
        fi
      done
    done

    if [[ -n "$failed" ]]; then
      notify \
        "podman auto-update issues on ${config.networking.hostName}" \
        "$(echo -e "Problems detected after auto-update:$failed")"
      exit 1
    fi
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
  provenanceAuditScript = pkgs.writeShellScript "podman-provenance-audit" ''
    set -euo pipefail

    expected_prefix="${userHome}/.config/systemd/user/"
    failed=0
    needs_reload=0

    for unit in ${lib.concatStringsSep " " (map lib.escapeShellArg stackUnits)}; do
      show_output="$(systemctl --user show "$unit" -p FragmentPath -p DropInPaths -p NeedDaemonReload -p UnitFileState -p LoadState 2>/dev/null || true)"
      load_state="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^LoadState=/{print $2}')"
      fragment_path="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^FragmentPath=/{print $2}')"
      drop_in_paths="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^DropInPaths=/{print $2}')"
      needs_daemon_reload="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^NeedDaemonReload=/{print $2}')"

      if [ -z "$show_output" ] || [ "$load_state" = "not-found" ]; then
        echo "ERROR: provenance-audit: missing stack unit $unit" >&2
        failed=1
        continue
      fi

      if [[ "$fragment_path" != "$expected_prefix"* ]]; then
        echo "ERROR: provenance-audit: $unit FragmentPath outside HM user path: $fragment_path" >&2
        failed=1
      fi

      if [[ -n "$drop_in_paths" && "$drop_in_paths" == *"/etc/systemd/user/"* ]]; then
        echo "ERROR: provenance-audit: $unit has /etc drop-ins: $drop_in_paths" >&2
        failed=1
      fi

      if [ "$needs_daemon_reload" = "yes" ]; then
        needs_reload=1
      fi
    done

    if [ "$needs_reload" -eq 1 ]; then
      systemctl --user daemon-reload
    fi

    if [ "$failed" -ne 0 ]; then
      echo "ERROR: provenance-audit failed" >&2
      exit 1
    fi
  '';
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

    stackUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "Internal registry of stack lifecycle user units.";
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.users.${user} = lib.mkIf (stackUnits != []) {
      xdg.configFile = stackUnitForceAttrs;

      home.activation.podmanStackUnitAutoHeal = inputs.home-manager.lib.hm.dag.entryBefore ["checkLinkTargets"] ''
        set -euo pipefail

        for unit in ${lib.concatStringsSep " " (map lib.escapeShellArg stackUnits)}; do
          unit_path="${userHome}/.config/systemd/user/$unit"
          if [ -e "$unit_path" ] && [ ! -L "$unit_path" ]; then
            rm -f "$unit_path"
          fi
        done
      '';

      home.activation.podmanStackUnitOwnership = inputs.home-manager.lib.hm.dag.entryAfter ["reloadSystemd"] ''
        set -euo pipefail

        systemctl_user() {
          env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            PATH="/run/current-system/sw/bin:$PATH" \
            systemctl --user "$@"
        }

        systemd_status="$(systemctl_user is-system-running 2>&1 || true)"
        if [[ "$systemd_status" != "running" && "$systemd_status" != "degraded" ]]; then
          echo "ERROR: user systemd manager unavailable for ${user}; cannot verify stack unit ownership" >&2
          exit 1
        fi

        expected_prefix="${userHome}/.config/systemd/user/"
        failed=0

        for unit in ${lib.concatStringsSep " " (map lib.escapeShellArg stackUnits)}; do
          show_output="$(systemctl_user show "$unit" -p FragmentPath -p DropInPaths -p LoadState -p UnitFileState 2>/dev/null || true)"
          load_state="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^LoadState=/{print $2}')"
          fragment_path="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^FragmentPath=/{print $2}')"
          drop_in_paths="$(echo "$show_output" | /run/current-system/sw/bin/awk -F= '/^DropInPaths=/{print $2}')"

          if [ -z "$show_output" ] || [ "$load_state" = "not-found" ]; then
            echo "ERROR: stack unit $unit is missing from user manager" >&2
            failed=1
            continue
          fi

          if [[ "$fragment_path" != "$expected_prefix"* ]]; then
            echo "ERROR: stack unit $unit has unexpected FragmentPath: $fragment_path" >&2
            failed=1
          fi

          if [[ -n "$drop_in_paths" && "$drop_in_paths" == *"/etc/systemd/user/"* ]]; then
            echo "ERROR: stack unit $unit has DropInPaths under /etc/systemd/user: $drop_in_paths" >&2
            failed=1
          fi
        done

        if [ "$failed" -ne 0 ]; then
          echo "ERROR: podman stack unit ownership invariants failed" >&2
          exit 1
        fi
      '';

      systemd.user = {
        startServices = "sd-switch";

        services.podman-provenance-audit = {
          Unit = {
            Description = "Podman stack unit provenance audit";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${provenanceAuditScript}";
          };
          Install = {
            WantedBy = ["default.target"];
          };
        };

        timers.podman-provenance-audit = {
          Unit = {
            Description = "Podman provenance audit timer";
          };
          Timer = {
            OnBootSec = "3m";
            OnUnitActiveSec = "15m";
            Unit = "podman-provenance-audit.service";
          };
          Install = {
            WantedBy = ["timers.target"];
          };
        };
      };
    };

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
      # podman, slirp4netns, fuse-overlayfs already provided by
      # virtualisation.podman.enable — only list extras here.
      systemPackages = lib.mkOrder 1600 (with pkgs; [
        docker-compose
        buildah
        skopeo
        shadow
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

    # Ensure podman user socket is restarted during activation
    # This handles the transition from system service to user socket
    system.activationScripts.podmanUserSocket = lib.stringAfter ["users"] ''
      # Restart user socket to ensure it's properly initialized
      export XDG_RUNTIME_DIR=/run/user/${toString userUid}
      /run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/systemctl --user daemon-reload || true
      if /run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/systemctl --user is-enabled podman.socket 2>/dev/null; then
        /run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/systemctl --user restart podman.socket || true
      fi
    '';

    systemd = {
      # Enable native podman user socket with socket activation
      user.sockets.podman = {
        wantedBy = ["sockets.target"];
      };

      services = {
        podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
          description = "Podman auto-update (rootless)";
          serviceConfig = {
            Type = "oneshot";
            # "" clears the base service's ExecStart (podman package ships its own)
            # so our script is the only one that runs — avoids double auto-update.
            ExecStart = ["" autoUpdateScript];
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
