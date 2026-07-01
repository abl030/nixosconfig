# prom rpool off-box backup — runs on doc1 (the bastion).
#
# Orchestrates a weekly full ZFS send of prom's rpool through doc1 to tower:
#   1. zfs snapshot -r rpool@<tag>  (on prom)
#   2. zfs send -R | zstd | age -e  (piped prom → doc1 → tower; encrypted in flight)
#   3. rename .tmp → final; sha256 sidecar  (on tower; age AEAD catches corruption at decrypt)
#   4. write status JSON  (locally on doc1)
#   5. prune old backups on tower (keep last <keepCount>)
#   6. prune old snapshots on prom (keep last <keepSnapshotsOnProm>)
#
# Encryption: archives are age-encrypted on doc1 before writing to tower.
#   Recipients: break-glass key (Bitwarden) + doc1 editor key (~/.config/sops/age/).
#   To decrypt: age -d -i ~/.config/sops/age/keys.txt <file>.zfs.zst.age | zstd -d | zfs receive -F rpool
#
# Monitoring: homelab.monitoring.errorPatterns watches the unit exit-code;
# the separate prom-rpool-backup-watchdog service watches the status JSON age.
#
# SSH keys:
#   prom  — dedicated sops-managed key (prom-rpool-backup-key); authorized on
#           prom with from="192.168.1.29" restriction. Gives root@prom access,
#           used for snapshot + zfs send.
#   tower — doc1 root's fleet key (~/.ssh/id_ed25519); already authorized on
#           tower. The service runs as root so picks it up automatically.
#
# Full runbook + bare-metal restore: docs/wiki/infrastructure/prom-rpool-backup-restore.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.promRpoolBackup;
  sshKey = config.sops.secrets."prom-rpool-backup/key".path;

  # Build age -r flags from the recipient key list at Nix eval time.
  ageArgs = lib.concatMapStringsSep " " (k: "-r ${lib.escapeShellArg k}") cfg.encryptTo;

  backupScript = pkgs.writeShellApplication {
    name = "prom-rpool-backup";
    runtimeInputs = with pkgs; [openssh coreutils jq util-linux age];
    text = ''
      set -uo pipefail

      PROM="${cfg.promHost}"
      TOWER="${cfg.towerHost}"
      TOWER_DIR="${cfg.towerDir}"
      KEY="${sshKey}"
      STATUS_FILE="${cfg.statusDir}/.status.json"
      KEEP_BACKUPS=${toString cfg.keepCount}
      KEEP_SNAPS=${toString cfg.keepSnapshotsOnProm}
      KNOWN_HOSTS="${cfg.statusDir}/known_hosts"

      # Wrapper functions avoid word-splitting issues with SSH options in variables.
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

      # SNAP_TAG used for rpool snapshot names (prom-rpool- prefix distinguishes
      # automated backups from manual/one-off snapshots). FILE uses just the date
      # so the filename matches the original manual format (prom-rpool-FULL-YYYY-MM-DD).
      SNAP_TAG="prom-rpool-$(date +%F)"
      DATE_TAG="$(date +%F)"
      FILE="prom-rpool-FULL-$DATE_TAG.zfs.zst.age"

      START_EPOCH=$(date -u +%s)
      START_ISO=$(date -u -Iseconds)
      LAST_ERR=""
      RC=0

      logger -t prom-rpool-backup "begin: snapshot=$SNAP_TAG target=$TOWER:$TOWER_DIR/$FILE"

      # 1. Snapshot
      logger -t prom-rpool-backup "step 1/6: zfs snapshot -r rpool@$SNAP_TAG"
      ssh_prom "zfs snapshot -r rpool@$SNAP_TAG" || {
        LAST_ERR="zfs snapshot failed rc=$?"
        RC=1
        logger -t prom-rpool-backup "FAILED: $LAST_ERR"
      }

      # 2. Send (pipe prom → doc1 → age → tower; write to .tmp first, rename on success)
      # age encrypts in flight on doc1 before hitting tower; recipients baked at build time.
      if [ "$RC" -eq 0 ]; then
        logger -t prom-rpool-backup "step 2/6: zfs send | zstd | age-encrypt → tower"
        ssh_prom "zfs send -R rpool@$SNAP_TAG | zstd -T0 -3" \
          | age -e ${ageArgs} \
          | ssh_tower "cat > $TOWER_DIR/$FILE.tmp" || {
          LAST_ERR="zfs send/encrypt/transfer failed rc=$?"
          RC=1
          logger -t prom-rpool-backup "FAILED: $LAST_ERR — cleaning .tmp"
          ssh_tower "rm -f $TOWER_DIR/$FILE.tmp" || true
        }
      fi

      # 3. Atomic rename + sha256 sidecar
      # age uses AEAD (ChaCha20-Poly1305) — corruption is caught at decrypt time.
      # The sha256 sidecar lets kopia and spot-checks detect bitrot independently.
      if [ "$RC" -eq 0 ]; then
        logger -t prom-rpool-backup "step 3/6: rename + sha256 sidecar"
        ssh_tower "mv $TOWER_DIR/$FILE.tmp $TOWER_DIR/$FILE \
          && sha256sum $TOWER_DIR/$FILE > $TOWER_DIR/$FILE.sha256" || {
          LAST_ERR="rename/sha256 failed rc=$?"
          RC=1
          logger -t prom-rpool-backup "FAILED: $LAST_ERR"
        }
      fi

      END_EPOCH=$(date -u +%s)
      END_ISO=$(date -u -Iseconds)
      DURATION=$((END_EPOCH - START_EPOCH))

      # 4. Write status JSON
      logger -t prom-rpool-backup "step 4/6: write status JSON"
      OK_BOOL=false
      [ "$RC" -eq 0 ] && OK_BOOL=true
      BACKUP_FILE=""
      [ "$RC" -eq 0 ] && BACKUP_FILE="$TOWER_DIR/$FILE"
      jq -n \
        --arg host "${config.networking.hostName}" \
        --arg unit "prom-rpool-backup" \
        --arg snapshot "rpool@$SNAP_TAG" \
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

      # 5. Prune old backups on tower (keep the last KEEP_BACKUPS .zfs.zst.age files by time)
      if [ "$RC" -eq 0 ]; then
        logger -t prom-rpool-backup "step 5/6: prune tower (keep $KEEP_BACKUPS)"
        ssh_tower "cd $TOWER_DIR \
          && ls -t prom-rpool-*.zfs.zst.age 2>/dev/null \
          | tail -n +$((KEEP_BACKUPS + 1)) \
          | xargs -r rm -v" 2>&1 | logger -t prom-rpool-backup || true
        # Remove .sha256 sidecars for deleted files and any stale .tmp files
        ssh_tower "cd $TOWER_DIR \
          && for sha in prom-rpool-*.sha256; do \
               base=\"\''${sha%.sha256}\"; \
               [ -f \"\$base\" ] || rm -f \"\$sha\"; \
             done; \
          rm -f prom-rpool-*.tmp" 2>&1 | logger -t prom-rpool-backup || true
      fi

      # 6. Prune old rpool snapshots on prom (keep last KEEP_SNAPS unique tags)
      #    Uses -s creation to sort by creation time; extracts the tag suffix,
      #    deduplicates, and destroys all but the most recent KEEP_SNAPS tags.
      if [ "$RC" -eq 0 ]; then
        logger -t prom-rpool-backup "step 6/6: prune prom snapshots (keep $KEEP_SNAPS)"
        # We capture the list here (on doc1) and destroy remotely one tag at a time
        # to avoid complex quoting of a while-loop inside a remote SSH string.
        # Extract the tag suffix (after @) from each snapshot name, dedup, then
        # keep only the oldest ones (those NOT in the last KEEP_SNAPS unique tags).
        # -s creation sorts oldest→newest; head -n -N removes the last N lines.
        TO_DESTROY=$(ssh_prom \
          "zfs list -H -t snapshot -o name -s creation -r rpool \
             | sed 's/.*@//' | sort -u | head -n -$KEEP_SNAPS" 2>&1) || true
        if [ -n "$TO_DESTROY" ]; then
          while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            logger -t prom-rpool-backup "destroying rpool@$tag"
            ssh_prom "zfs destroy -r rpool@$tag" 2>&1 | logger -t prom-rpool-backup || true
          done <<< "$TO_DESTROY"
        else
          logger -t prom-rpool-backup "no old snapshots to prune"
        fi
      fi

      logger -t prom-rpool-backup "end rc=$RC duration=''${DURATION}s ok=$OK_BOOL"
      exit "$RC"
    '';
  };

  watchdogScript = pkgs.writeShellApplication {
    name = "prom-rpool-backup-check";
    runtimeInputs = with pkgs; [jq coreutils];
    text = ''
      set -u
      STATUS="${cfg.statusDir}/.status.json"
      MAX_AGE_SEC=$(( ${toString cfg.watchdogMaxAgeDays} * 86400 ))

      if [ ! -f "$STATUS" ]; then
        echo "PROM-RPOOL-BACKUP FAIL reason=status-file-missing path=$STATUS"
        exit 1
      fi

      AGE=$(( $(date +%s) - $(stat -c %Y "$STATUS") ))
      if [ "$AGE" -gt "$MAX_AGE_SEC" ]; then
        echo "PROM-RPOOL-BACKUP FAIL reason=status-file-stale age_seconds=$AGE max_seconds=$MAX_AGE_SEC"
        exit 1
      fi

      OK=$(jq -r '.ok // empty' "$STATUS")
      RC=$(jq -r '.exit_code // empty' "$STATUS")
      FINISHED=$(jq -r '.finished_at // "unknown"' "$STATUS")
      DURATION=$(jq -r '.duration_seconds // empty' "$STATUS")
      SNAPSHOT=$(jq -r '.snapshot // empty' "$STATUS")
      LAST_ERR=$(jq -r '.last_error // empty' "$STATUS")

      if [ -z "$OK" ] && [ -z "$RC" ]; then
        echo "PROM-RPOOL-BACKUP placeholder (no backup run yet) finished_at=$FINISHED"
        exit 0
      fi

      if [ "$OK" != "true" ] || [ "$RC" != "0" ]; then
        echo "PROM-RPOOL-BACKUP FAIL reason=last-run-failed exit_code=$RC last_error=\"$LAST_ERR\" finished_at=$FINISHED"
        exit 1
      fi

      echo "PROM-RPOOL-BACKUP OK snapshot=$SNAPSHOT finished_at=$FINISHED duration_seconds=$DURATION"
    '';
  };
in {
  options.homelab.services.promRpoolBackup = {
    enable = lib.mkEnableOption "weekly off-box backup of prom rpool to tower";

    promHost = lib.mkOption {
      type = lib.types.str;
      default = "root@192.168.1.12";
      description = "SSH target for prom (user@host).";
    };

    towerHost = lib.mkOption {
      type = lib.types.str;
      default = "root@tower";
      description = "SSH target for tower (user@host). Uses root's default identity.";
    };

    towerDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/user/VMBackups/prom-rpool";
      description = "Directory on tower where backup files are stored.";
    };

    statusDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prom-rpool-backup";
      description = "Local directory on doc1 for state files (known_hosts, status JSON).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Mon *-*-* 03:30:00";
      description = "systemd OnCalendar expression. Defaults to weekly Monday 03:30.";
    };

    keepCount = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of backup files to keep on tower (oldest pruned first).";
    };

    keepSnapshotsOnProm = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Number of distinct rpool snapshot tags to retain on prom.";
    };

    encryptTo = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "age1y6nasu9gplutapjne4yv0uhzrwee6ayf2mygwhphf3nty6x5xddqy4zl4h" # break-glass (Bitwarden)
        "age17uw7vxe8x3nmg0lu5j33qlh8pxr538jlqhhjngmexdc0macccg8sc8rw63" # editor (doc1 ~/.config/sops/age)
      ];
      description = ''
        age public keys to encrypt backup archives to before writing to tower.
        Default: break-glass (Bitwarden) + doc1 editor key.
        Decrypt: age -d -i ~/.config/sops/age/keys.txt <file>.zfs.zst.age | zstd -d | zfs receive -F rpool
      '';
    };

    watchdogMaxAgeDays = lib.mkOption {
      type = lib.types.int;
      default = 9;
      description = ''
        Alert if the status file is older than this many days. Weekly schedule
        + 2-day grace = 9 days catches a missed run without false-positiving
        on a one-off late run.
      '';
    };

    watchdogInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "How often the watchdog check runs.";
    };
  };

  config = lib.mkIf cfg.enable {
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

    systemd.services.prom-rpool-backup = {
      description = "Weekly full ZFS send of prom rpool to tower (age-encrypted)";
      documentation = ["file:///run/current-system/etc/nixos/docs/wiki/infrastructure/prom-rpool-backup-restore.md"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/prom-rpool-backup";
        # Generous timeout: ~17 GB send over LAN at ~100 MB/s + zstd + age
        TimeoutStartSec = "4h";
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 5;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.prom-rpool-backup = {
      description = "Weekly prom rpool backup to tower";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "15min";
        Unit = "prom-rpool-backup.service";
      };
    };

    # Watchdog: checks status JSON age once daily, pages on stale/failed.
    systemd.services.prom-rpool-backup-watchdog = {
      description = "Check prom rpool backup status file freshness";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchdogScript}/bin/prom-rpool-backup-check";
        StandardOutput = "journal";
        StandardError = "journal";
        NoNewPrivileges = true;
      };
    };

    systemd.timers.prom-rpool-backup-watchdog = {
      description = "Daily prom rpool backup freshness check";
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
        name = "prom rpool backup failed";
        unit = "prom-rpool-backup.service";
        pattern = "Failed with result|Main process exited, code=exited, status=";
        severity = "critical";
        summary = "prom rpool weekly backup to tower failed";
        threshold = 0;
        description = ''
          The weekly prom rpool backup job (prom-rpool-backup.service on doc1) exited
          non-zero. Run `journalctl -u prom-rpool-backup.service -n 100` to see which
          step failed. Manual re-run: `sudo systemctl start prom-rpool-backup.service`.
        '';
      }
      {
        name = "prom rpool backup watchdog";
        unit = "prom-rpool-backup-watchdog.service";
        pattern = "PROM-RPOOL-BACKUP FAIL";
        severity = "warning";
        summary = "prom rpool backup is stale or failed";
        threshold = 0;
        description = ''
          The daily watchdog found ${cfg.statusDir}/.status.json missing, older than
          ${toString cfg.watchdogMaxAgeDays} days, or reporting a failed run. Means
          the weekly backup timer hasn't run recently or the last run errored.
          Check: `systemctl status prom-rpool-backup.timer prom-rpool-backup.service`
          and `cat ${cfg.statusDir}/.status.json`.
        '';
      }
    ];
  };
}
