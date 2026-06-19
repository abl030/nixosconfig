{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.podman;

  containerType = lib.types.submodule {
    options = {
      unit = lib.mkOption {
        type = lib.types.str;
        description = "Systemd unit name (e.g. podman-youtarr.service).";
      };
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OCI image reference. When set, only restart if a newer image was pulled. When null, always restart (for compose stacks).";
      };
    };
  };

  # Build the update script from registered container entries
  restartScript = let
    podman = config.virtualisation.podman.package;
  in
    pkgs.writeShellScript "podman-update-containers" ''
      set -euo pipefail

      podman=${podman}/bin/podman
      failed=""
      updated=0
      skipped=0
      total=0

      ${lib.concatMapStringsSep "\n" (entry: ''
          total=$((total + 1))
          unit=${lib.escapeShellArg entry.unit}
          ${
            if entry.image != null
            then ''
              image=${lib.escapeShellArg entry.image}
              old_id=$($podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "missing")
              $podman pull "$image" >/dev/null 2>&1 || true
              new_id=$($podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "missing")

              if [[ "$old_id" == "$new_id" ]]; then
                echo "Skipping $unit (image $image unchanged)"
                skipped=$((skipped + 1))
              else
                echo "Updating $unit (image $image changed)"
                if systemctl restart "$unit"; then
                  updated=$((updated + 1))
                else
                  failed="$failed\n  $unit"
                fi
              fi
            ''
            else ''
              echo "Restarting $unit (no image tracking)"
              if systemctl restart "$unit"; then
                updated=$((updated + 1))
              else
                failed="$failed\n  $unit"
              fi
            ''
          }
        '')
        cfg.containers}

      if [[ -n "$failed" ]]; then
        echo "Container update: $updated updated, $skipped unchanged, failures:" >&2
        echo -e "$failed" >&2
        exit 1
      fi

      echo "Container update complete: $updated updated, $skipped unchanged (of $total)"
    '';
in {
  options.homelab.podman = {
    enable = lib.mkEnableOption "Rootful podman OCI container infrastructure";

    # Runtime-hardening baseline prepended to every homelab OCI container's
    # extraOptions. We never pin images — `:latest` + auto-pull stays on
    # fleet-wide by explicit policy (#232 TIER-4 is WONTFIX). So the
    # compensating control for a compromised auto-pulled image is to shrink
    # its runtime authority: drop ALL Linux capabilities and forbid privilege
    # escalation via setuid. Each container --cap-add=<CAP> back only the
    # minimal set it needs (s6/LSIO inits that chown then drop to PUID need
    # CHOWN,SETUID,SETGID,DAC_OVERRIDE,FOWNER,KILL; privileged-port binders
    # need NET_BIND_SERVICE). readOnly so a module can't silently weaken the
    # baseline — exceptions are additive via cap-add, never by dropping this.
    # See docs/wiki/nixos-service-modules.md "Container runtime hardening".
    hardenOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [
        "--security-opt=no-new-privileges"
        "--cap-drop=all"
      ];
      description = "Baseline cap-drop + no-new-privileges flags for OCI containers; prepend to extraOptions, cap-add minimal caps back per container.";
    };

    updateSchedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:00:00";
      description = "OnCalendar schedule for pulling and restarting containers.";
    };

    pruneSchedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "OnCalendar schedule for podman system prune.";
    };

    containers = lib.mkOption {
      type = lib.types.listOf containerType;
      default = [];
      internal = true;
      description = "Registry of container units for the update timer. Set image to enable smart pull-compare updates.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      autoPrune = {
        enable = true;
        dates = cfg.pruneSchedule;
        flags = ["--all"];
      };
    };

    virtualisation.oci-containers.backend = "podman";

    # Allow DNS from containers on the podman network
    networking.firewall.interfaces.podman0.allowedUDPPorts = [53];

    systemd = {
      services.podman-update-containers = lib.mkIf (cfg.containers != []) {
        description = "Pull and restart OCI containers";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = restartScript;
        };
      };

      timers.podman-update-containers = lib.mkIf (cfg.containers != []) {
        description = "Daily OCI container update timer";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.updateSchedule;
          Persistent = true;
        };
      };
    };
  };
}
