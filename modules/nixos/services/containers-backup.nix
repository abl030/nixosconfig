# containers-backup — doc1-orchestrated weekly backup of /nvmeprom/containers to tower.
#
# Takes an atomic ZFS snapshot of nvmeprom/containers on prom, tars the
# snapshot contents (with opt-out exclusions) through doc1 to a .tar.gz on
# tower, verifies the archive, then destroys the snapshot. New services under
# /nvmeprom/containers are included automatically — add to cfg.excludeDirs to
# explicitly skip.
#
# Steps:
#   1. zfs snapshot nvmeprom/containers@<tag>  (on prom — atomic, instantaneous)
#   2. tar snapshot | gzip → pipe through doc1 → .tar.gz.tmp on tower
#   3. mv tmp → final file; tar -tzf integrity check on tower
#   4. write status JSON  (locally on doc1)
#   5. zfs destroy <snapshot>  (on prom)
#   6. prune old .tar.gz files on tower (keep last <keepCount>)
#
# SSH keys:
#   prom  — reuses prom-rpool-backup/key (same sops secret, same from= auth on prom)
#   tower — doc1 root's fleet key (~/.ssh/id_ed25519); runs as root so picked up automatically
#
# Opt-out model: cfg.excludeDirs lists relative directory names to skip. Anything
# NOT in the list is backed up. Add large/regeneratable dirs here; new services
# are covered by default.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.containersBackup;
  # Reuse the prom root key that the rpool backup already has authorized on prom.
  sshKey = config.sops.secrets."prom-rpool-backup/key".path;

  excludeArgs = lib.concatMapStringsSep " " (d: "--exclude=${lib.escapeShellArg d}") cfg.excludeDirs;

  backupScript = pkgs.writeShellApplication {
    name = "containers-backup";
    runtimeInputs = with pkgs; [openssh coreutils jq util-linux];
    text = ''
      set -uo pipefail

      PROM="${cfg.promHost}"
      TOWER="${cfg.towerHost}"
      TOWER_DIR="${cfg.towerDir}"
      KEY="${sshKey}"
      DATASET="${cfg.promDataset}"
      MOUNTPOINT="${cfg.promMountpoint}"
      STATUS_FILE="${cfg.statusDir}/.status.json"
      KEEP=${toString cfg.keepCount}
      KNOWN_HOSTS="${cfg.statusDir}/known_hosts"

      ssh_prom() {
        ssh -i "$KEY" \
          -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$KNOWN_HOSTS" \
          "$PROM" "$@"
      }
      ssh_tower() {
        ssh \
          -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$KNOWN_HOSTS" \
          "$TOWER" "$@"
      }

      SNAP_TAG="containers-backup-$(date +%F)"
      FILE="containers-backup-$(date +%F).tar.gz"
      SNAP_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAP_TAG"

      START_EPOCH=$(date -u +%s)
      START_ISO=$(date -u -Iseconds)
      LAST_ERR=""
      RC=0

      logger -t containers-backup "begin: snapshot=$DATASET@$SNAP_TAG file=$FILE"

      # 1. Snapshot
      logger -t containers-backup "step 1/6: zfs snapshot $DATASET@$SNAP_TAG"
      ssh_prom "zfs snapshot $DATASET@$SNAP_TAG" || {
        LAST_ERR="zfs snapshot failed rc=$?"
        RC=1
        logger -t containers-backup "FAILED: $LAST_ERR"
      }

      # 2. tar snapshot → pipe through doc1 → .tmp on tower
      # Excludes are baked in at Nix eval time (${excludeArgs}).
      # --exclude=.zfs is a safety net in case snapdir is ever set to visible.
      if [ "$RC" -eq 0 ]; then
        logger -t containers-backup "step 2/6: tar snapshot | gzip → tower"
        ssh_prom "tar -C $SNAP_PATH ${excludeArgs} --exclude=.zfs -czf - ." \
          | ssh_tower "cat > $TOWER_DIR/$FILE.tmp" || {
          LAST_ERR="tar/transfer failed rc=$?"
          RC=1
          logger -t containers-backup "FAILED: $LAST_ERR — cleaning .tmp"
          ssh_tower "rm -f $TOWER_DIR/$FILE.tmp" || true
        }
      fi

      # 3. Atomic rename + integrity check (list archive — confirms gzip header + EOF)
      if [ "$RC" -eq 0 ]; then
        logger -t containers-backup "step 3/6: rename + tar integrity check"
        ssh_tower "mv $TOWER_DIR/$FILE.tmp $TOWER_DIR/$FILE \
          && tar -tzf $TOWER_DIR/$FILE > /dev/null" || {
          LAST_ERR="rename/verify failed rc=$?"
          RC=1
          logger -t containers-backup "FAILED: $LAST_ERR"
        }
      fi

      END_EPOCH=$(date -u +%s)
      END_ISO=$(date -u -Iseconds)
      DURATION=$((END_EPOCH - START_EPOCH))

      # 4. Write status JSON
      logger -t containers-backup "step 4/6: write status JSON"
      OK_BOOL=false
      [ "$RC" -eq 0 ] && OK_BOOL=true
      BACKUP_FILE=""
      [ "$RC" -eq 0 ] && BACKUP_FILE="$TOWER_DIR/$FILE"
      jq -n \
        --arg host "${config.networking.hostName}" \
        --arg unit "containers-backup" \
        --arg snapshot "$DATASET@$SNAP_TAG" \
        --arg backup_file "$BACKUP_FILE" \
        --arg started_at "$START_ISO" \
        --arg finished_at "$END_ISO" \
        --argjson duration_seconds "$DURATION" \
        --argjson exit_code "$RC" \
        --argjson ok "$OK_BOOL" \
        --arg last_error "$LAST_ERR" \
        '{host: $host, unit: $unit, snapshot: $snapshot, backup_file: $backup_file,
          started_at: $started_at, finished_at: $finished_at,
          duration_seconds: $duration_seconds, exit_code: $exit_code,
          ok: $ok, last_error: $last_error}' > "$STATUS_FILE"
      chmod 644 "$STATUS_FILE"

      # 5. Destroy the snapshot
      logger -t containers-backup "step 5/6: destroy snapshot $DATASET@$SNAP_TAG"
      ssh_prom "zfs destroy $DATASET@$SNAP_TAG" 2>&1 | logger -t containers-backup || {
        # Log but don't fail the job — backup succeeded, leftover snapshot is harmless
        logger -t containers-backup "WARNING: snapshot destroy failed — may need manual cleanup"
      }

      # 6. Prune old backups on tower (keep last KEEP by mtime)
      if [ "$RC" -eq 0 ]; then
        logger -t containers-backup "step 6/6: prune tower (keep $KEEP)"
        ssh_tower "cd $TOWER_DIR \
          && ls -t containers-backup-*.tar.gz 2>/dev/null \
          | tail -n +$((KEEP + 1)) \
          | xargs -r rm -v" 2>&1 | logger -t containers-backup || true
        ssh_tower "rm -f $TOWER_DIR/containers-backup-*.tmp" 2>&1 | logger -t containers-backup || true
      fi

      logger -t containers-backup "end rc=$RC duration=''${DURATION}s ok=$OK_BOOL"
      exit "$RC"
    '';
  };

  watchdogScript = pkgs.writeShellApplication {
    name = "containers-backup-check";
    runtimeInputs = with pkgs; [jq coreutils];
    text = ''
      set -u
      STATUS="${cfg.statusDir}/.status.json"
      MAX_AGE_SEC=$(( ${toString cfg.watchdogMaxAgeDays} * 86400 ))

      if [ ! -f "$STATUS" ]; then
        echo "CONTAINERS-BACKUP FAIL reason=status-file-missing path=$STATUS"
        exit 1
      fi

      AGE=$(( $(date +%s) - $(stat -c %Y "$STATUS") ))
      if [ "$AGE" -gt "$MAX_AGE_SEC" ]; then
        echo "CONTAINERS-BACKUP FAIL reason=status-file-stale age_seconds=$AGE max_seconds=$MAX_AGE_SEC"
        exit 1
      fi

      OK=$(jq -r '.ok // empty' "$STATUS")
      RC=$(jq -r '.exit_code // empty' "$STATUS")
      FINISHED=$(jq -r '.finished_at // "unknown"' "$STATUS")
      DURATION=$(jq -r '.duration_seconds // empty' "$STATUS")
      SNAPSHOT=$(jq -r '.snapshot // empty' "$STATUS")
      LAST_ERR=$(jq -r '.last_error // empty' "$STATUS")

      if [ -z "$OK" ] && [ -z "$RC" ]; then
        echo "CONTAINERS-BACKUP placeholder (no backup run yet) finished_at=$FINISHED"
        exit 0
      fi

      if [ "$OK" != "true" ] || [ "$RC" != "0" ]; then
        echo "CONTAINERS-BACKUP FAIL reason=last-run-failed exit_code=$RC last_error=\"$LAST_ERR\" finished_at=$FINISHED"
        exit 1
      fi

      echo "CONTAINERS-BACKUP OK snapshot=$SNAPSHOT finished_at=$FINISHED duration_seconds=$DURATION"
    '';
  };
in {
  options.homelab.services.containersBackup = {
    enable = lib.mkEnableOption "weekly off-box backup of /nvmeprom/containers to tower";

    promHost = lib.mkOption {
      type = lib.types.str;
      default = "root@192.168.1.12";
      description = "SSH target for prom.";
    };

    promDataset = lib.mkOption {
      type = lib.types.str;
      default = "nvmeprom/containers";
      description = "ZFS dataset to snapshot on prom.";
    };

    promMountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/nvmeprom/containers";
      description = "Mountpoint of promDataset on prom (used to access .zfs/snapshot/).";
    };

    towerHost = lib.mkOption {
      type = lib.types.str;
      default = "root@tower";
      description = "SSH target for tower.";
    };

    towerDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/user/VMBackups/containers";
      description = "Directory on tower where backup archives are stored.";
    };

    statusDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/containers-backup";
      description = "Local directory on doc1 for state files (known_hosts, status JSON).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Wed *-*-* 03:30:00";
      description = "systemd OnCalendar. Defaults to weekly Wednesday 03:30 (offset from rpool Monday run).";
    };

    keepCount = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of backup archives to keep on tower.";
    };

    excludeDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Music" # NFS re-export from tower — not ours to back up
        "music" # Lidarr-managed library — large media, not config
        "kopia" # Kopia's own repo data — already backed up off-site
        "jellyfin" # Thumbnails/metadata cache — fully regeneratable
        "loki" # Log data — ephemeral, not worth backing up
      ];
      description = ''
        Directory names under promMountpoint to exclude from the backup.
        These are relative top-level names (e.g. "Music", not a full path).
        New services are included by default — add here to explicitly opt out.
      '';
    };

    watchdogMaxAgeDays = lib.mkOption {
      type = lib.types.int;
      default = 9;
      description = ''
        Alert if status file is older than this many days. Weekly schedule +
        2-day grace = 9 days catches a missed run without false-positiving.
      '';
    };

    watchdogInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "How often the watchdog runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Reuse the prom root SSH key that prom-rpool-backup already has authorized.
    # sops-nix deduplicates identical secret declarations from multiple modules.
    sops.secrets."prom-rpool-backup/key" = {
      sopsFile = config.homelab.secrets.sopsFile "prom-rpool-backup-key";
      format = "binary";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.statusDir} 0700 root root - -"
    ];

    systemd.services.containers-backup = {
      description = "Weekly backup of /nvmeprom/containers snapshot to tower";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/containers-backup";
        # ~10 GB tar over LAN + gzip. 2h is generous.
        TimeoutStartSec = "2h";
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 5;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.containers-backup = {
      description = "Weekly /nvmeprom/containers backup to tower";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "15min";
        Unit = "containers-backup.service";
      };
    };

    systemd.services.containers-backup-watchdog = {
      description = "Check containers backup status file freshness";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchdogScript}/bin/containers-backup-check";
        StandardOutput = "journal";
        StandardError = "journal";
        NoNewPrivileges = true;
      };
    };

    systemd.timers.containers-backup-watchdog = {
      description = "Daily containers backup freshness check";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.watchdogInterval;
        Persistent = true;
        AccuracySec = "1m";
        RandomizedDelaySec = "10m";
      };
    };

    homelab.monitoring.errorPatterns = [
      {
        name = "containers backup failed";
        unit = "containers-backup.service";
        pattern = "Failed with result|Main process exited, code=exited, status=";
        severity = "critical";
        summary = "prom containers weekly backup to tower failed";
        threshold = 0;
        description = ''
          containers-backup.service on doc1 exited non-zero. Run
          `journalctl -u containers-backup.service -n 100` to see which step
          failed. Manual re-run: `sudo systemctl start containers-backup.service`.
          If a snapshot was left behind: `ssh root@192.168.1.12 "zfs list -t snapshot nvmeprom/containers"`.
        '';
      }
      {
        name = "containers backup watchdog";
        unit = "containers-backup-watchdog.service";
        pattern = "CONTAINERS-BACKUP FAIL";
        severity = "warning";
        summary = "prom containers backup is stale or failed";
        threshold = 0;
        description = ''
          The daily watchdog found ${cfg.statusDir}/.status.json missing, older
          than ${toString cfg.watchdogMaxAgeDays} days, or reporting a failed run.
          Check: `systemctl status containers-backup.timer containers-backup.service`
          and `cat ${cfg.statusDir}/.status.json`.
        '';
      }
    ];
  };
}
