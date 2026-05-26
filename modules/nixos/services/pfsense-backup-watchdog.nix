# pfSense backup watchdog
#
# Watches the syncoid status JSON written by prom's syncoid-pfsense.service,
# AND a content canary inside the backup tree itself.
# Full architecture + restore procedures + prom-side rebuild steps:
#   docs/wiki/infrastructure/pfsense-backup.md
#
# Runs hourly, reads the status file via the read-only NFS mount from prom,
# and emits a distinctive log line on:
#   - missing status file
#   - status file older than maxAgeHours
#   - exit_code != 0 from the last syncoid run
#   - missing/empty canary file (the actual pfSense config.xml) — catches
#     the 2026-05-26 failure mode where the share was mounted but child
#     ZFS datasets weren't traversed, so the JSON file looked fine but
#     1.83 GB of real data was invisible. NFS with crossmnt fixes the
#     underlying issue, but the canary remains as defence-in-depth.
#   - total tree size below canaryMinBytes — catches a partial replication
#     that drops content but keeps the canary path intact.
#
# Loki picks up the journal output; `homelab.monitoring.errorPatterns` below
# routes the "PFSENSE-BACKUP FAIL" pattern through the alert-bridge → Gotify.
#
# Why a watchdog on doc2 rather than alerting on prom's syncoid-pfsense
# journal directly: even though prom DOES ship to Loki via the
# ansible-deployed alloy (we'd missed this for months — see the
# 2026-05-24 "stale alloy connection" incident in lgtm-stack.md, where
# prom's alloy was silently dropping every batch to a dead vhost IP),
# the status-file approach is structurally stronger:
#   1. Verifies the doc2 NFS share is mounted and readable
#      (catches a class of failure the journal alone can't see).
#   2. Independent of alloy/Loki health — if alloy goes silent again,
#      this watchdog still pages.
#   3. Reads the actual bytes kopia would back up, so an alert
#      means "the data kopia is shipping is broken", not just
#      "syncoid logged something".
# A prom-side journal alert via errorPatterns would be a useful
# *additional* signal but is not the primary defence.
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
      CANARY="${cfg.canaryFile}"
      CANARY_MIN_BYTES=${toString cfg.canaryMinBytes}
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

      # Content canary — verifies the actual backed-up tree is intact, not
      # just the status JSON. Catches the "mount is up, status is OK, but
      # the data is invisible" failure mode (2026-05-26 virtiofs incident).
      if [ ! -s "$CANARY" ]; then
        echo "PFSENSE-BACKUP FAIL reason=canary-missing path=$CANARY"
        exit 1
      fi

      CANARY_SIZE=$(stat -c %s "$CANARY")
      if [ "$CANARY_SIZE" -lt "$CANARY_MIN_BYTES" ]; then
        echo "PFSENSE-BACKUP FAIL reason=canary-too-small bytes=$CANARY_SIZE min=$CANARY_MIN_BYTES path=$CANARY"
        exit 1
      fi

      echo "PFSENSE-BACKUP OK finished_at=$FINISHED duration_seconds=$DURATION canary_bytes=$CANARY_SIZE"
    '';
  };
in {
  options.homelab.services.pfsenseBackupWatchdog = {
    enable = lib.mkEnableOption "watchdog for the pfSense ZFS backup status file";

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/pfsense/.syncoid-status.json";
      description = "Path to the JSON status file written by prom's syncoid wrapper.";
    };

    canaryFile = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/pfsense/ROOT/default/cf/conf/config.xml";
      description = ''
        A canary file inside the replicated tree that proves child datasets
        are mounted and traversable. Defaults to the live pfSense
        config.xml at its actual path (cf/conf/config.xml — the `cf`
        dataset is mounted at /mnt/backup/pfsense/ROOT/default/cf and
        contains a `conf/` directory with config.xml inside). The single
        most semantically meaningful file in the backup; if this is missing
        the backup is useless regardless of what other content survived.
      '';
    };

    canaryMinBytes = lib.mkOption {
      type = lib.types.int;
      # pfSense config.xml on this fleet is ~175 KB. 50 KB is a comfortable
      # "non-empty + non-truncated" floor — would catch the 298-byte
      # incident class without false-positiving on a real config slim-down.
      default = 51200;
      description = "Minimum size in bytes for the canary file before alerting.";
    };

    maxAgeHours = lib.mkOption {
      type = lib.types.int;
      default = 26;
      description = ''
        Maximum permitted age of the status file in hours. prom's syncoid timer
        runs daily (24h cadence) — anything older than this means the timer
        failed to run, prom is unreachable, or the NFS mount is broken.
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
        # Single-shot per watchdog run; "FAIL" prefix is emitted once
        # and the unit exits. Page immediately.
        threshold = 0;
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
