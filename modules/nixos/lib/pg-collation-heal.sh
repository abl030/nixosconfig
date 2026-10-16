# pg-collation-heal — rebuild collation-dependent indexes after the OS collation
# provider (glibc, or ICU) changes version under a running cluster.
#
# Why: a nixpkgs bump can move glibc (e.g. 2.42 -> 2.44). PostgreSQL's libc
# collations then sort text differently from the order baked into existing
# btree indexes. Lookups, ORDER BY ... LIMIT/OFFSET paging and UNIQUE
# enforcement silently go wrong (2026-10-16: the MusicBrainz mirror returned
# one release twice and dropped its sibling pressing from an artist browse).
# PostgreSQL only warns ("collation version mismatch"); nothing repairs it.
#
# What: for every connectable database whose recorded collation version (or
# any of its collation objects' versions) differs from what the OS provides,
# rebuild every index keyed on a non-C collation, then record the new version.
# Indexes are rebuilt CONCURRENTLY so the service stays up. The version is
# refreshed only after every rebuild in that database succeeded; a failure
# (for example a UNIQUE index that now holds duplicates) leaves the mismatch
# recorded, logs an ERROR line and exits non-zero, so the next PostgreSQL start
# retries and the warning stays visible.
#
# Runs as the postgres superuser over the local socket (peer auth). All verdict
# lines also go to syslog (/dev/log), which mk-pg-container binds to the host
# journal so they reach Loki from inside nspawn.
set -uo pipefail

tag=pg-collation-heal


log() {
  printf '%s\n' "$*"
  logger -t "$tag" -- "$*" 2>/dev/null || true
}

# Every connection to a mismatched database repeats the server's three-line
# "collation version mismatch" WARNING/DETAIL/HINT. It is sent during
# connection startup, before client_min_messages can apply, so filter exactly
# that message from psql's stderr; the verdict lines below say it once. Every
# other notice and error still passes through.
mismatch_noise='^(WARNING:  database ".*" has a collation version mismatch|DETAIL:  The database was created using collation version |HINT:  Rebuild all objects in this database that use the default collation)'

q() {
  local db="$1"
  shift
  psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$db" "$@" 2> >(grep -vE "$mismatch_noise" >&2)
}

# A libc collation imported at initdb whose locale the OS no longer ships makes
# pg_collation_actual_version() raise; treat that as "unknown", never stale.
safe_version_fn="CREATE FUNCTION pg_temp.cv(oid) RETURNS text LANGUAGE plpgsql AS \$f\$
BEGIN RETURN pg_collation_actual_version(\$1);
EXCEPTION WHEN others THEN RETURN NULL; END \$f\$;"

failures=0

# Run a query and split its rows into the named array. A query failure is a
# failure, never an empty result: an unread index list must not be mistaken
# for "nothing to rebuild" and let the version be refreshed over bad indexes.
# shellcheck disable=SC2034  # "into" is a nameref; assigning it fills the caller's array
rows() {
  local -n into="$1"
  local db="$2" out
  shift 2
  out=$(q "$db" "$@") || return 1
  into=()
  if [ -n "$out" ]; then
    mapfile -t into <<<"$out"
  fi
}

databases=()
rows databases postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname" || {
  log "ERROR: could not list databases"
  exit 1
}

for db in "${databases[@]}"; do
  db_state=$(q "$db" -F $'\t' -c "SELECT coalesce(datcollversion, ''), coalesce(pg_database_collation_actual_version(oid), '')
    FROM pg_database WHERE datname = current_database()
      AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)
      AND pg_database_collation_actual_version(oid) IS NOT NULL") || {
    log "ERROR: $db: could not read the database collation version"
    failures=$((failures + 1))
    continue
  }

  stale_collations=()
  rows stale_collations "$db" -c "$safe_version_fn" -c "SELECT oid::regcollation
    FROM pg_collation
    WHERE collversion IS NOT NULL
      AND pg_temp.cv(oid) IS NOT NULL
      AND collversion IS DISTINCT FROM pg_temp.cv(oid)
    ORDER BY 1" || {
    log "ERROR: $db: could not read collation object versions"
    failures=$((failures + 1))
    continue
  }

  if [ -z "$db_state" ] && [ "${#stale_collations[@]}" -eq 0 ]; then
    continue
  fi

  if [ -n "$db_state" ]; then
    log "$db: database collation version recorded ${db_state%%$'\t'*}, OS provides ${db_state##*$'\t'}; rebuilding collation-dependent indexes"
  fi
  if [ "${#stale_collations[@]}" -gt 0 ]; then
    log "$db: collation objects with a changed version: ${stale_collations[*]}"
  fi

  # Leftovers of an interrupted REINDEX CONCURRENTLY are invalid shadow indexes.
  # Drop them first so the retry does not trip over them.
  leftovers=()
  rows leftovers "$db" -c "SELECT i.indexrelid::regclass FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE NOT i.indisvalid AND c.relname ~ '_cc(new|old)[0-9]*$'" || {
    log "ERROR: $db: could not list leftover invalid indexes"
    failures=$((failures + 1))
    continue
  }
  for idx in "${leftovers[@]}"; do
    log "$db: dropping leftover invalid index $idx from an interrupted rebuild"
    q "$db" -c "DROP INDEX CONCURRENTLY IF EXISTS $idx" || failures=$((failures + 1))
  done

  # Every index with at least one key column (or expression) under a collation
  # whose order is not fixed by definition. C/POSIX and builtin collations are
  # code-point ordered and never change; everything else is rebuilt.
  indexes=()
  rows indexes "$db" -F $'\t' -c "SELECT DISTINCT n.nspname IN ('pg_catalog', 'pg_toast'), i.indexrelid::regclass
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL unnest(i.indcollation::oid[]) AS k(coll)
    JOIN pg_collation co ON co.oid = k.coll
    WHERE k.coll <> 0
      AND i.indisvalid
      AND co.collprovider <> 'b'
      AND NOT (co.collprovider = 'c' AND co.collcollate IN ('C', 'POSIX'))
    ORDER BY 2" || {
    log "ERROR: $db: could not list collation-dependent indexes; version left unrefreshed"
    failures=$((failures + 1))
    continue
  }

  db_failures=0
  started=$SECONDS
  for row in "${indexes[@]}"; do
    is_catalog=${row%%$'\t'*}
    idx=${row#*$'\t'}
    if [ "$is_catalog" = t ]; then
      q "$db" -c "REINDEX INDEX $idx" || {
        log "ERROR: $db: rebuilding catalog index $idx failed"
        db_failures=$((db_failures + 1))
      }
    else
      q "$db" -c "REINDEX INDEX CONCURRENTLY $idx" || {
        log "ERROR: $db: rebuilding $idx failed (see the PostgreSQL log; a UNIQUE index may now hold duplicates)"
        db_failures=$((db_failures + 1))
      }
    fi
  done

  if [ "$db_failures" -gt 0 ]; then
    log "ERROR: $db: $db_failures of ${#indexes[@]} index rebuilds failed; collation version left unrefreshed so the next start retries"
    failures=$((failures + db_failures))
    continue
  fi

  for coll in "${stale_collations[@]}"; do
    q "$db" -c "ALTER COLLATION $coll REFRESH VERSION" || failures=$((failures + 1))
  done
  if [ -n "$db_state" ]; then
    q "$db" -c "ALTER DATABASE \"${db//\"/\"\"}\" REFRESH COLLATION VERSION" || failures=$((failures + 1))
  fi
  log "$db: rebuilt ${#indexes[@]} collation-dependent indexes in $((SECONDS - started))s and refreshed the collation version"
done

if [ "$failures" -gt 0 ]; then
  log "ERROR: finished with $failures failure(s)"
  exit 1
fi
