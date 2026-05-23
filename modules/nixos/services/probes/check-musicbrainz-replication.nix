# Deep freshness probe for the MusicBrainz mirror's replication state.
#
# Why this exists:
#   `mirror.sh` (cron wrapper inside the MB container) swallows
#   `LoadReplicationChanges` failures with `... || { echo failed ; }` so the
#   systemd unit exits 0 even when no packets land. The mirror silently froze
#   for ~13 days in May 2026 during the v-2026-05-11.0 schema-change rollout
#   because of this. The replication wrapper in musicbrainz.nix now fails the
#   unit on detection, but this probe gives a second, state-based signal that
#   doesn't depend on the daily unit running at all.
#
# What it checks:
#   `replication_control.last_replication_date` against
#   $MB_MAX_REPLICATION_AGE_HOURS (default 36h — daily run + 12h slack).
#   Also exits non-zero if `current_schema_sequence` drifts below
#   $MB_EXPECTED_SCHEMA_SEQUENCE (set from MUSICBRAINZ_DB_SCHEMA_SEQUENCE in
#   the env, which is the upstream codebase value).
#
# Auth: reads $MB_PGPASS_FILE (sops dotenv with POSTGRES_PASSWORD).
{pkgs}:
pkgs.writeShellApplication {
  name = "check-musicbrainz-replication";
  runtimeInputs = with pkgs; [postgresql_18 coreutils gnugrep];
  text = ''
    set -uo pipefail

    host="''${MB_PG_HOST:?MB_PG_HOST not set}"
    port="''${MB_PG_PORT:-5432}"
    user="''${MB_PG_USER:-musicbrainz}"
    db="''${MB_PG_DB:-musicbrainz_db}"
    pgpass_file="''${MB_PGPASS_FILE:?MB_PGPASS_FILE not set}"
    max_age_hours="''${MB_MAX_REPLICATION_AGE_HOURS:-36}"
    expected_schema="''${MB_EXPECTED_SCHEMA_SEQUENCE:-0}"

    if [ ! -r "$pgpass_file" ]; then
      echo "[probe] pgpass file unreadable: $pgpass_file" >&2
      exit 2
    fi

    PGPASSWORD=$(grep '^POSTGRES_PASSWORD=' "$pgpass_file" | cut -d= -f2-)
    if [ -z "$PGPASSWORD" ]; then
      echo "[probe] POSTGRES_PASSWORD missing from $pgpass_file" >&2
      exit 2
    fi
    export PGPASSWORD

    # Single row from replication_control; format:
    #   <current_schema_sequence>|<age_seconds_or_NULL>
    row=$(psql \
      -h "$host" -p "$port" -U "$user" -d "$db" \
      -v ON_ERROR_STOP=1 -tAc \
      "SELECT current_schema_sequence,
              COALESCE(EXTRACT(EPOCH FROM (now() - last_replication_date))::bigint::text, 'NULL')
       FROM replication_control LIMIT 1" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "[probe] psql exit $rc: $row" >&2
      exit 1
    fi

    schema=''${row%%|*}
    age_secs=''${row##*|}

    if [ "$age_secs" = "NULL" ]; then
      echo "[probe] last_replication_date IS NULL (mirror has never replicated?)" >&2
      exit 1
    fi

    max_secs=$((max_age_hours * 3600))
    if [ "$age_secs" -gt "$max_secs" ]; then
      age_hours=$((age_secs / 3600))
      echo "[probe] last replication is ''${age_hours}h old (max ''${max_age_hours}h)" >&2
      exit 1
    fi

    if [ "$expected_schema" -gt 0 ] && [ "$schema" -lt "$expected_schema" ]; then
      echo "[probe] DB schema sequence $schema < expected $expected_schema (codebase ahead — replication blocked)" >&2
      exit 1
    fi

    exit 0
  '';
}
