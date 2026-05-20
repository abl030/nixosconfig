# Deep freshness probe for a Kopia repository.
#
# Queries kopia's /api/v1/sources, parses the `lastSnapshot.endTime` for
# each source, and exits non-zero if any source is older than
# $KOPIA_MAX_AGE_HOURS. The deep-probe oneshot in monitoring_sync.nix
# pushes UP to Kuma on exit 0; on failure no push happens and Kuma flips
# DOWN after the configured maxretries.
#
# Catches the failure modes #254 was filed for:
#   - kopia daemon hung / OOM'd → no new snapshots → endTime ages out
#   - schedule misconfigured / disabled → snapshots stop silently
#   - underlying repository unreachable for hours → snapshots fail and
#     `lastSnapshot.endTime` stays pinned to the last successful run
#
# Out of scope: per-snapshot errorCount > 0 (already covered by the
# existing JSON-query Kuma monitor in kopia.nix, "Kopia <name> Backup").
# Repository-broken errors during a run are caught by the #253
# errorPatterns on kopia-{mum,photos}.service.
#
# Auth: reads $KOPIA_AUTH_FILE (a sops dotenv with KOPIA_SERVER_USER and
# KOPIA_SERVER_PASSWORD). Same secret the existing Kuma JSON monitor
# uses — no new secret needed.
{pkgs}:
pkgs.writeShellApplication {
  name = "check-kopia-fresh";
  runtimeInputs = with pkgs; [curl jq coreutils gnugrep];
  text = ''
    set -uo pipefail

    base="''${KOPIA_BASE_URL:?KOPIA_BASE_URL not set}"
    auth_file="''${KOPIA_AUTH_FILE:?KOPIA_AUTH_FILE not set}"
    max_age_hours="''${KOPIA_MAX_AGE_HOURS:-36}"

    if [ ! -r "$auth_file" ]; then
      echo "[probe] auth file unreadable: $auth_file" >&2
      exit 2
    fi

    user=$(grep ^KOPIA_SERVER_USER "$auth_file" | cut -d= -f2-)
    pass=$(grep ^KOPIA_SERVER_PASSWORD "$auth_file" | cut -d= -f2-)
    if [ -z "$user" ] || [ -z "$pass" ]; then
      echo "[probe] missing KOPIA_SERVER_USER or KOPIA_SERVER_PASSWORD in $auth_file" >&2
      exit 2
    fi

    # Fetch source list.
    resp=$(curl -sS --max-time 15 --connect-timeout 5 -u "$user:$pass" "$base/api/v1/sources")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "[probe] curl exit $rc fetching $base/api/v1/sources" >&2
      exit 1
    fi

    # Parse + check. jq exit:
    #   0 = all sources fresh, output count
    #   1 = at least one source stale, output names+ages
    #   2 = parse error / no sources
    result=$(printf '%s' "$resp" | jq -r --argjson max_secs "$((max_age_hours * 3600))" '
      if (.sources | length) == 0 then
        "EMPTY"
      else
        [ .sources[] | {
          path: .source.path,
          last: (.lastSnapshot.endTime // null)
        } ] as $rows |
        ($rows | map(select(.last == null)) ) as $never |
        (now) as $now |
        ($rows
          | map(select(.last != null))
          | map(. + {age: ($now - (.last | fromdateiso8601))})
          | map(select(.age > $max_secs))) as $stale |
        if ($never | length) > 0 then
          "NEVER " + (($never | map(.path)) | join(", "))
        elif ($stale | length) > 0 then
          "STALE " + (($stale | map("\(.path) (\((.age / 3600 | floor))h)")) | join(", "))
        else
          "OK"
        end
      end
    ')

    case "$result" in
      OK)
        exit 0
        ;;
      EMPTY)
        echo "[probe] kopia /api/v1/sources returned no sources" >&2
        exit 1
        ;;
      NEVER*)
        echo "[probe] source has never snapshotted: ''${result#NEVER }" >&2
        exit 1
        ;;
      STALE*)
        echo "[probe] sources older than ''${max_age_hours}h: ''${result#STALE }" >&2
        exit 1
        ;;
      *)
        echo "[probe] unexpected output from jq: $result" >&2
        echo "[probe] raw response (truncated): $(printf '%s' "$resp" | head -c 500)" >&2
        exit 1
        ;;
    esac
  '';
}
