# pfSense backup watchdog
#
# Watches the syncoid status JSON written by prom's syncoid-pfsense.service
# (see docs/wiki/infrastructure/pfsense-dns-resolver.md). Runs hourly,
# reads the status file via the read-only virtiofs mount, and emits a
# distinctive log line on:
#   - missing status file
#   - status file older than maxAgeHours
#   - exit_code != 0 from the last syncoid run
#
# Loki picks up the journal output; `homelab.monitoring.errorPatterns` below
# routes the "PFSENSE-BACKUP FAIL" pattern through the alert-bridge → Gotify.
#
# Why a watchdog on doc2 rather than alerting on prom: prom does not ship
# logs to Loki (its journal lives only on the box). The status file pattern
# crosses the prom/doc2 boundary via virtiofs and lets the existing alerting
# fabric on doc2 do the rest. See discussion in the 2026-05-23 backup-design
# session.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.pfsenseBackupWatchdog;

  checkScript = pkgs.writeShellApplication {
    name = "pfsense-backup-check";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      set -u
      STATUS="${cfg.statusFile}"
      MAX_AGE_SEC=$(( ${toString cfg.maxAgeHours} * 3600 ))

      if [ ! -f "$STATUS" ]; then
        echo "PFSENSE-BACKUP FAIL reason=status-file-missing path=$STATUS"
        exit 1
      fi

      AGE=$(( $(date +%s) - $(stat -c %Y "$STATUS") ))
      if [ "$AGE" -gt "$MAX_AGE_SEC" ]; then
        echo "PFSENSE-BACKUP FAIL reason=status-file-stale age_seconds=$AGE max_seconds=$MAX_AGE_SEC"
        exit 1
      fi

      OK=$(jq -r '.ok // empty' "$STATUS")
      RC=$(jq -r '.exit_code // empty' "$STATUS")
      FINISHED=$(jq -r '.finished_at // .initialized_at // "unknown"' "$STATUS")
      DURATION=$(jq -r '.duration_seconds // empty' "$STATUS")
      LAST_ERR=$(jq -r '.last_error // empty' "$STATUS")

      # The placeholder file (before first scheduled run) has neither ok nor
      # exit_code — treat that as informational, not a failure.
      if [ -z "$OK" ] && [ -z "$RC" ]; then
        echo "PFSENSE-BACKUP placeholder (no syncoid run yet) finished_at=$FINISHED"
        exit 0
      fi

      if [ "$OK" != "true" ] || [ "$RC" != "0" ]; then
        echo "PFSENSE-BACKUP FAIL reason=last-run-failed exit_code=$RC last_error=\"$LAST_ERR\" finished_at=$FINISHED"
        exit 1
      fi

      echo "PFSENSE-BACKUP OK finished_at=$FINISHED duration_seconds=$DURATION"
    '';
  };
in {
  options.homelab.services.pfsenseBackupWatchdog = {
    enable = lib.mkEnableOption "watchdog for the pfSense ZFS backup status file";

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/pfsense-backup/.syncoid-status.json";
      description = "Path to the JSON status file written by prom's syncoid wrapper.";
    };

    maxAgeHours = lib.mkOption {
      type = lib.types.int;
      default = 26;
      description = ''
        Maximum permitted age of the status file in hours. prom's syncoid timer
        runs daily (24h cadence) — anything older than this means the timer
        failed to run, prom is unreachable, or virtiofs is broken.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar expression for the watchdog check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.pfsense-backup-watchdog = {
      description = "Check pfSense backup syncoid status file";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkScript}/bin/pfsense-backup-check";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.timers.pfsense-backup-watchdog = {
      description = "Hourly pfSense backup status check";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        AccuracySec = "1m";
        RandomizedDelaySec = "5m";
      };
    };

    # Route "PFSENSE-BACKUP FAIL ..." through the existing alert pipeline.
    homelab.monitoring.errorPatterns = [
      {
        name = "pfSense backup watchdog";
        unit = "pfsense-backup-watchdog.service";
        pattern = "PFSENSE-BACKUP FAIL";
        severity = "warning";
        summary = "pfSense ZFS backup is stale, failed, or unreachable";
        description = ''
          The doc2-side watchdog can't see a healthy ${cfg.statusFile}.
          Most likely causes: prom's syncoid-pfsense.timer failed to run,
          prom is down, the virtiofs share is broken, or the syncoid pull
          itself exited non-zero. Inspect the matched line for the failure
          reason; on prom run `journalctl -u syncoid-pfsense.service -n 100`
          and `systemctl status syncoid-pfsense.timer`.
        '';
      }
    ];
  };
}
