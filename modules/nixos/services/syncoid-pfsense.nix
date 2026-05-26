# syncoid-pfsense — pull pfSense's ZFS pool into a local ZFS pool on this host.
#
# Replaces the prom-side imperative wrapper (was /usr/local/sbin/syncoid-pfsense.sh)
# after the 2026-05-26 cutover. Architecture rationale:
#   - prom's nvmeprom hosted the replicated dataset and exposed it to doc2 via
#     virtiofs/NFS. Both surfaces couldn't traverse the 12 child ZFS datasets
#     reliably (virtiofsd's --announce-submounts only propagated one child;
#     kernel NFS server on Linux can't crossmnt ZFS-on-Linux child datasets
#     even with explicit per-child fsids — see kernel.org reexport docs).
#   - Solution: doc2 gets a passthrough zvol from prom, runs native ZFS, syncoid
#     pulls directly here. kopia reads local-filesystem paths. prom drops out
#     of the backup chain entirely.
#
# Full architecture + recovery procedures + 2026-05-26 cutover history:
#   docs/wiki/infrastructure/pfsense-backup.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.syncoidPfsense;
  sshKey = config.sops.secrets."syncoid-pfsense/key".path;

  # Wrapper script. Same masking logic as the retired prom script:
  # syncoid returns rc=2 with a "Cowardly refusing to destroy your existing
  # target" critical line when the wrapper TOP-level dataset (`pfsensebackup`
  # in our case) was created out-of-band (i.e. when we made the pool).
  # Every CHILD dataset still replicates fine. Mask that exact line to rc=0.
  syncoidScript = pkgs.writeShellApplication {
    name = "syncoid-pfsense";
    runtimeInputs = with pkgs; [sanoid openssh coreutils gnugrep util-linux mbuffer];
    # writeShellApplication wraps with `set -euo pipefail` by default. That
    # turns syncoid's expected rc=2 (the documented benign wrapper-refusal)
    # into an immediate script exit before we can mask it and write the
    # status JSON. Disable errexit ONLY around the syncoid call, then turn
    # it back on for the rest.
    text = ''
      KEY="${sshKey}"
      SOURCE="${cfg.source}"
      TARGET="${cfg.target}"
      MOUNTPOINT="${cfg.mountpoint}"
      STATUS_FILE="$MOUNTPOINT/.syncoid-status.json"
      WRAPPER_BENIGN_RE='Cowardly refusing to destroy your existing target'

      START_EPOCH=$(date -u +%s)
      START_ISO=$(date -u -Iseconds)

      logger -t syncoid-pfsense "begin pull from $SOURCE to $TARGET"

      TMPOUT=$(mktemp)
      trap 'rm -f "$TMPOUT"' EXIT

      EXCLUDE_ARGS=()
      ${lib.concatMapStringsSep "\n" (ds: ''EXCLUDE_ARGS+=(--exclude=${lib.escapeShellArg ds})'') cfg.excludeDatasets}

      # Disable errexit/pipefail around syncoid so we can capture rc=2
      # cleanly and mask the benign wrapper-refusal case below.
      set +e
      set +o pipefail
      syncoid --recursive \
        "''${EXCLUDE_ARGS[@]}" \
        --sshkey="$KEY" \
        --sshoption=StrictHostKeyChecking=accept-new \
        --sshoption=UserKnownHostsFile=/var/lib/syncoid-pfsense/known_hosts \
        "$SOURCE" "$TARGET" 2>&1 | tee "$TMPOUT" | logger -t syncoid-pfsense
      RC=''${PIPESTATUS[0]}
      set -e
      set -o pipefail

      END_EPOCH=$(date -u +%s)
      END_ISO=$(date -u -Iseconds)
      DURATION=$((END_EPOCH - START_EPOCH))

      # syncoid prints "CRITICAL ERROR:" then the actual error on the next
      # line. grep the whole file (not just the matching line) for the
      # benign-refusal phrase. Capture the LAST critical-marker block for
      # the status JSON so operators see context, not just "rc=2".
      LAST_ERR=$(grep -iE -A2 "CRITICAL|ERROR|FATAL" "$TMPOUT" | tail -3 | tr -d '"' | head -c 500)

      if [ "$RC" -eq 2 ] && grep -qE "$WRAPPER_BENIGN_RE" "$TMPOUT"; then
        logger -t syncoid-pfsense "wrapper-dataset refusal is benign (children replicated) — overriding rc=2 -> 0"
        LAST_ERR="(masked benign wrapper refusal) $LAST_ERR"
        RC=0
      fi

      # Write status JSON for the watchdog. Must be at the path the watchdog
      # expects (homelab.services.pfsenseBackupWatchdog.statusFile).
      cat > "$STATUS_FILE" <<JSON
      {
        "host": "${config.networking.hostName}",
        "unit": "syncoid-pfsense",
        "source": "$SOURCE",
        "target": "$TARGET",
        "started_at": "$START_ISO",
        "finished_at": "$END_ISO",
        "duration_seconds": $DURATION,
        "exit_code": $RC,
        "ok": $([ "$RC" -eq 0 ] && echo true || echo false),
        "last_error": "$LAST_ERR"
      }
      JSON
      chmod 644 "$STATUS_FILE"

      logger -t syncoid-pfsense "end pull rc=$RC duration=''${DURATION}s"
      exit "$RC"
    '';
  };
in {
  options.homelab.services.syncoidPfsense = {
    enable = lib.mkEnableOption "syncoid pull of pfSense ZFS pool";

    source = lib.mkOption {
      type = lib.types.str;
      default = "root@192.168.1.1:pfSense";
      description = "syncoid source spec (user@host:zfspoolname).";
    };

    target = lib.mkOption {
      type = lib.types.str;
      default = "pfsensebackup";
      description = "Local ZFS dataset to receive into (typically a pool name).";
    };

    mountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/pfsense";
      description = ''
        Mountpoint of the target pool's root dataset. Used to locate the
        status JSON file that the watchdog reads. Must match the actual
        ZFS `mountpoint` property on the pool (set during bootstrap).
      '';
    };

    excludeDatasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["pfSense/var/db/ntopng"];
      description = "Source-side child datasets to skip (passed to syncoid --exclude).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:00:00";
      description = "systemd OnCalendar expression for the daily pull.";
    };

    sanoid = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable sanoid retention pruning of the received snapshots.
        autosnap=no (we receive sync-snaps from syncoid), autoprune=yes.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."syncoid-pfsense/key" = {
      sopsFile = config.homelab.secrets.sopsFile "syncoid-pfsense-key";
      format = "binary";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # Need the ssh client and sanoid in the system path (for ad-hoc invocation
    # and so that the systemd unit's ExecStart finds them via runtimeInputs).
    environment.systemPackages = with pkgs; [sanoid];

    # State dir for known_hosts TOFU file (so pfSense's host key gets pinned
    # after first connection — survives reboots).
    systemd.tmpfiles.rules = [
      "d /var/lib/syncoid-pfsense 0700 root root - -"
    ];

    systemd.services.syncoid-pfsense = {
      description = "Pull pfSense ZFS pool via syncoid";
      documentation = ["https://github.com/abl030/nixosconfig/blob/master/docs/wiki/infrastructure/pfsense-backup.md"];
      after = ["network-online.target" "zfs-import.target"];
      wants = ["network-online.target"];
      requires = ["zfs-import.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncoidScript}/bin/syncoid-pfsense";
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 5;
        # No NoNewPrivileges — syncoid invokes zfs subcommands.
      };
    };

    systemd.timers.syncoid-pfsense = {
      description = "Daily pfSense ZFS pull";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "5min";
        Unit = "syncoid-pfsense.service";
      };
    };

    # Sanoid prunes received snapshots per the same retention policy that
    # was on prom: 30 daily / 8 weekly / 6 monthly, no autosnap (syncoid
    # writes the sync-snapshots, sanoid only prunes).
    services.sanoid = lib.mkIf cfg.sanoid {
      enable = true;
      interval = "*:0/15";
      datasets.${cfg.target} = {
        recursive = true;
        processChildrenOnly = false;
        autosnap = false;
        autoprune = true;
        hourly = 0;
        daily = 30;
        weekly = 8;
        monthly = 6;
        yearly = 0;
      };
    };

    # Surface syncoid failures through the existing alert pipeline. The
    # pfsense-backup-watchdog (which reads the status JSON we write above)
    # is the primary signal; this is a journald-level safety net for the
    # case where the unit fails BEFORE writing the status file.
    homelab.monitoring.errorPatterns = [
      {
        name = "syncoid-pfsense failed";
        unit = "syncoid-pfsense.service";
        pattern = "(?i)CRITICAL|FATAL|connection refused|permission denied";
        severity = "warning";
        summary = "syncoid pull of pfSense ZFS pool failed";
        threshold = 0;
      }
    ];
  };
}
