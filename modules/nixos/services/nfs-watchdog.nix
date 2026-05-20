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
            svc=${lib.escapeShellArg "${name}.service"}
            if ! timeout 10 stat ${lib.escapeShellArg entry.path} >/dev/null 2>&1; then
              # NFS path is dead. Clear any start-limit-hit residue before
              # restarting so the watchdog isn't gagged by systemd burst caps
              # during a long outage (services like paperless / podman exhaust
              # the default 5-in-10s burst within seconds when their bind/volume
              # source is gone).
              echo "${name}: NFS path ${entry.path} is stale, restarting" >&2
              systemctl reset-failed "$svc" 2>/dev/null || true
              systemctl restart "$svc"
            elif ! systemctl is-active --quiet "$svc"; then
              # Path is healthy but the service is dead — typical after an NFS
              # outage that outlasted the service's restart burst. Bring it
              # back; the watchdog is the single source of recovery here.
              echo "${name}: NFS path ${entry.path} healthy but service is down, recovering" >&2
              systemctl reset-failed "$svc" 2>/dev/null || true
              systemctl start "$svc"
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

    # See #253 audit + rules-doc "Per-service errorPatterns".
    # Single uniform alert for ALL watchdog units. Warning, not critical —
    # the watchdog is doing its job — but persistent firing indicates
    # genuine NFS flakiness that needs human eyes.
    homelab.monitoring.errorPatterns = [
      {
        name = "NFS watchdog tripped";
        unit = ".+-nfs-watchdog\\.service";
        unitIsRegex = true;
        pattern = "(?i)NFS path .* (is stale, restarting|healthy but service is down, recovering)";
        severity = "warning";
        summary = "an NFS-dependent service was restarted by its watchdog";
        description = ''
          The watchdog stat-probed an NFS mount, it failed, the dependent
          service got restarted. Single trip can be a one-off blip
          (tower or Synology rebooted). Repeated trips on the same
          service = real NFS path is unhealthy; check
          docs/wiki/infrastructure/nfs-over-tailscale.md.
        '';
      }
    ];
  };
}
