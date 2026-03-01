# NFS watchdog — restarts services when NFS paths go stale.
#
# Services opt in with one line:
#   homelab.nfsWatchdog.<service-name>.path = "/mnt/data/...";
#
# This generates a <name>-nfs-watchdog.timer + .service pair that periodically
# stats the path and restarts the service if the NFS handle is dead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.nfsWatchdog;

  watchdogEntry = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "NFS path to health-check via stat.";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = "How often to check (systemd OnUnitActiveSec format).";
      };
    };
  };
in {
  options.homelab.nfsWatchdog = lib.mkOption {
    type = lib.types.attrsOf watchdogEntry;
    default = {};
    description = "Per-service NFS watchdog definitions.";
  };

  config = lib.mkIf (cfg != {}) {
    systemd.services = lib.mapAttrs' (name: entry:
      lib.nameValuePair "${name}-nfs-watchdog" {
        description = "NFS watchdog for ${name}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "${name}-nfs-watchdog" ''
            if ! timeout 10 stat ${lib.escapeShellArg entry.path} >/dev/null 2>&1; then
              echo "${name}: NFS path ${entry.path} is stale, restarting" >&2
              systemctl restart ${lib.escapeShellArg "${name}.service"}
            fi
          '';
        };
      })
    cfg;

    systemd.timers = lib.mapAttrs' (name: entry:
      lib.nameValuePair "${name}-nfs-watchdog" {
        description = "NFS watchdog timer for ${name}";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = entry.interval;
        };
      })
    cfg;
  };
}
