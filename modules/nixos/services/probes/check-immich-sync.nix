# Deep write-path probe for Immich.
#
# Runs `SELECT 1 FROM asset_edit_audit LIMIT 1` against the immich
# database AS THE IMMICH ROLE (over the nspawn veth TCP, same auth path
# the immich app uses). This catches the exact #250 failure mode —
# `permission denied for table asset_edit_audit` — at the SQL layer,
# independent of any application-level retry/wrap logic.
#
# Why not probe via Immich's HTTP API? Upstream Immich (≥2.x) blocks
# API-key auth on /api/sync/* endpoints:
#   {"message":"Sync endpoints cannot be used with API keys",
#    "error":"Forbidden","statusCode":403}
# Sync is reserved for cookie-authenticated app sessions. Going through
# the user's session would require storing an email+password and
# implementing the login dance — gross. A direct SQL probe is surgical:
# it tests the precise table-permission state, doesn't need additional
# secrets, and survives Immich API churn.
#
# Auth: reads the password from $IMMICH_PG_PASSWORD_FILE (path to a
# sops dotenv with POSTGRES_PASSWORD=...). The same pgpass already
# used by immich-server.service — no new secret needed.
#
# Endpoint state:
#   exit 0 → table readable → push UP to Kuma
#   exit 1 → permission denied or any other SQL error → no push, monitor flips DOWN
#   exit 2 → environment/secret missing → no push, monitor flips DOWN
{pkgs}:
pkgs.writeShellApplication {
  name = "check-immich-sync";
  runtimeInputs = with pkgs; [postgresql_16 coreutils gnugrep];
  text = ''
    set -uo pipefail

    host="''${IMMICH_PG_HOST:-192.168.100.5}"
    port="''${IMMICH_PG_PORT:-5432}"
    user="''${IMMICH_PG_USER:-immich}"
    db="''${IMMICH_PG_DB:-immich}"
    pwd_file="''${IMMICH_PG_PASSWORD_FILE:?IMMICH_PG_PASSWORD_FILE not set}"
    table="''${IMMICH_PG_TABLE:-asset_edit_audit}"

    if [ ! -r "$pwd_file" ]; then
      echo "[probe] password file unreadable: $pwd_file" >&2
      exit 2
    fi

    PGPASSWORD=$(grep ^POSTGRES_PASSWORD= "$pwd_file" | cut -d= -f2-)
    if [ -z "$PGPASSWORD" ]; then
      echo "[probe] empty POSTGRES_PASSWORD in $pwd_file" >&2
      exit 2
    fi
    export PGPASSWORD

    # ON_ERROR_STOP so psql returns non-zero on the permission-denied
    # error (default is to print error and exit 0 for SELECT failures).
    # application_name tags the connection so DDL audit alerts and
    # log-line forensics can distinguish probe traffic from real app.
    # -A -t -q together = unaligned, tuples-only, quiet — no banner.
    if ! psql \
      -h "$host" -p "$port" -U "$user" -d "$db" \
      -v ON_ERROR_STOP=1 \
      -A -t -q \
      -c "SET application_name = 'check-immich-sync-probe'" \
      -c "SELECT 1 FROM \"$table\" LIMIT 1" \
      >/dev/null 2>/tmp/check-immich-sync.err; then
      echo "[probe] psql failed:" >&2
      cat /tmp/check-immich-sync.err >&2
      rm -f /tmp/check-immich-sync.err
      exit 1
    fi
    rm -f /tmp/check-immich-sync.err
    exit 0
  '';
}
