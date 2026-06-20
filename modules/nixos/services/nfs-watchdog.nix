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
          NoNewPrivileges = true; # stat + systemctl only; no setuid exec (#232)
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
            elif systemctl is-failed --quiet "$svc"; then
              # Path is healthy but the service is in the FAILED state —
              # typical after an NFS outage that outlasted the service's
              # restart burst (start-limit-hit → failed). Bring it back; the
              # watchdog is the single source of recovery here.
              #
              # NB: test `is-failed`, NOT `! is-active`. A Type=oneshot/timer
              # service (e.g. mailarchive-{work,gmail}) sits at inactive(dead)
              # between runs — that is its NORMAL resting state, not "down".
              # `! is-active` treated every idle tick as a failure and
              # "recovered" the service every 5 min (156×/13h on the healthy
              # mailarchive-work, NRestarts=0 — 2026-06-19 triage), firing the
              # NFS-watchdog alert nonstop and kicking a needless extra sync
              # each tick. is-failed fires only on a genuinely failed unit,
              # which is exactly the documented intent above.
              echo "${name}: NFS path ${entry.path} healthy but service is failed, recovering" >&2
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
        pattern = "(?i)NFS path .* (is stale, restarting|healthy but service is (down|failed), recovering)";
        severity = "warning";
        summary = "an NFS-dependent service was restarted by its watchdog";
        # Single-shot per watchdog tick (5min interval). One tripped
        # mount = one log line per cycle; default threshold=2 would
        # need 3 cycles ≈ 15min before paging. Keep eager.
        threshold = 0;
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
