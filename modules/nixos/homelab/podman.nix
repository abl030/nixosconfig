{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.podman;

  # Build the restart script from registered container units
  restartScript = pkgs.writeShellScript "podman-update-containers" ''
    set -euo pipefail

    failed=""
    succeeded=0
    total=0

    for unit in ${lib.concatStringsSep " " (map lib.escapeShellArg cfg.containers)}; do
      total=$((total + 1))
      echo "Restarting: $unit"
      if systemctl restart "$unit"; then
        succeeded=$((succeeded + 1))
      else
        failed="$failed\n  $unit"
      fi
    done

    if [[ -n "$failed" ]]; then
      echo "Container update failed: $((total - succeeded))/$total units failed" >&2
      echo -e "Failed units:$failed" >&2
      exit 1
    fi

    echo "All $total container units restarted successfully"
  '';
in {
  options.homelab.podman = {
    enable = lib.mkEnableOption "Rootful podman OCI container infrastructure";

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
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "Registry of podman-<name>.service unit names for the restart timer.";
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
