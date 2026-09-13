# Deep backup-error probe for a Kopia repository.
# See docs/wiki/services/kopia.md "Freshness monitoring" section and the
# triage note in docs/wiki/services/lgtm-stack.md.
#
# Companion to check-kopia-fresh.nix. Where the freshness probe catches
# "no NEW snapshot landed within KOPIA_MAX_AGE_HOURS", this one catches
# "snapshots ARE landing but completing with file errors (errorCount > 0)".
#
# WHY a deep probe instead of the old json-query Kuma monitor: the previous
# monitor failed on a SINGLE snapshot with errorCount > 0. Because kopia's
# errorCount is sticky (it reflects only `lastSnapshot`, which persists until
# the next daily snapshot ~24h later), one transient incomplete snapshot —
# e.g. a file changed/locked mid-snapshot, or a hiccup over the slow 1 MB/s
# Tailscale link to mum's Synology — paged "Backup DOWN" and stayed down for
# a day. The /api/v1/sources endpoint only exposes lastSnapshot, so "require
# two consecutive bad snapshots" cannot be expressed as a json-query. This
# probe queries /api/v1/snapshots (full history) and only fails when a
# source's TWO most recent snapshots BOTH have errorCount > 0 — a genuinely
# sustained problem, not a one-off. (2026-06-09 triage; #254 follow-up.)
#
# Auth: reads $KOPIA_AUTH_FILE (a sops dotenv with KOPIA_SERVER_USER and
# KOPIA_SERVER_PASSWORD). Same secret the freshness probe uses.
{pkgs}:
pkgs.writeShellApplication {
  name = "check-kopia-backup-errors";
  runtimeInputs = with pkgs; [curl jq coreutils gnugrep];
  text = ''
    set -uo pipefail
    ${builtins.readFile ./kopia-curl-auth.sh}

    base="''${KOPIA_BASE_URL:?KOPIA_BASE_URL not set}"
    auth_file="''${KOPIA_AUTH_FILE:?KOPIA_AUTH_FILE not set}"

    if [ ! -r "$auth_file" ]; then
      echo "[probe] auth file unreadable: $auth_file" >&2
      exit 2
    fi

    kopia_auth_user=$(grep ^KOPIA_SERVER_USER "$auth_file" | cut -d= -f2-)
    kopia_auth_pass=$(grep ^KOPIA_SERVER_PASSWORD "$auth_file" | cut -d= -f2-)
    if [ -z "$kopia_auth_user" ] || [ -z "$kopia_auth_pass" ]; then
      echo "[probe] missing KOPIA_SERVER_USER or KOPIA_SERVER_PASSWORD in $auth_file" >&2
      exit 2
    fi
    kopia_curl_bin=curl

    # --max-time 250s mirrors check-kopia-fresh.nix: sits under the deepProbe's
    # TimeoutStartSec=300s and absorbs kopia's full-maintenance repository lock.
    if ! sources=$(kopia_curl -fsS --max-time 250 --connect-timeout 5 "$base/api/v1/sources"); then
      echo "[probe] unable to fetch $base/api/v1/sources" >&2
      exit 1
    fi

    # Unknown responses must never become a healthy heartbeat. The sources
    # and history endpoints have DIFFERENT shapes; see the 2026-09-13 RCA.
    if ! printf '%s' "$sources" | jq -e '
      def count_ok: type == "number" and . >= 0 and . == floor;
      (.sources | type == "array" and length > 0) and
      all(.sources[];
        (.source.host | type == "string" and length > 0) and
        (.source.userName | type == "string" and length > 0) and
        (.source.path | type == "string" and startswith("/")) and
        (.lastSnapshot.stats.errorCount | count_ok))
    ' >/dev/null; then
      echo "[probe] invalid or empty sources response; backup health unknown" >&2
      exit 1
    fi

    # Narrow to sources whose LATEST snapshot has errors; only those need a
    # history lookup. Tab-separated host\tuserName\tpath per source.
    bad=$(printf '%s' "$sources" | jq -r '
      .sources[]
      | select(.lastSnapshot.stats.errorCount > 0)
      | [.source.host, .source.userName, .source.path] | @tsv')

    if [ -z "$bad" ]; then
      exit 0
    fi

    consecutive=""
    while IFS=$'\t' read -r shost suser spath; do
      [ -z "$spath" ] && continue

      if ! hist=$(kopia_curl -fsS --max-time 250 --connect-timeout 5 -G \
        --data-urlencode "host=$shost" \
        --data-urlencode "userName=$suser" \
        --data-urlencode "path=$spath" \
        "$base/api/v1/snapshots"); then
        echo "[probe] unable to fetch snapshot history for $spath" >&2
        exit 1
      fi

      if ! printf '%s' "$hist" | jq -e '
        def count_ok: type == "number" and . >= 0 and . == floor;
        (.snapshots | type == "array" and length > 0) and
        all(.snapshots[];
          (.endTime | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
          (.summary.numFailed | count_ok))
      ' >/dev/null; then
        echo "[probe] invalid or empty snapshot history for $spath; backup health unknown" >&2
        exit 1
      fi

      # History exposes summary.numFailed, not the sources endpoint's
      # lastSnapshot.stats.errorCount. Defaulting the absent stats to zero
      # used to hide every consecutive-error case (2026-09-13 RCA).
      # Verdict over the two most recent snapshots:
      #   both   - last TWO snapshots errored        -> sustained, page
      #   one    - last errored, previous was clean   -> transient, don't page
      #   single - only one snapshot exists           -> can't be consecutive
      verdict=$(printf '%s' "$hist" | jq -r '
        .snapshots | sort_by(.endTime) | .[-2:] as $last2
        | if ($last2 | length) < 2 then "single"
          elif ($last2 | all(.[]; .summary.numFailed > 0)) then "both"
          else "one" end')

      case "$verdict" in
        both)
          consecutive="$consecutive $spath"
          ;;
        single)
          echo "[probe] $spath: only one snapshot and it errored (not yet consecutive)" >&2
          ;;
        one)
          echo "[probe] $spath: last snapshot errored but previous was clean (transient, not paging)" >&2
          ;;
        *)
          echo "[probe] $spath: unexpected verdict from jq: $verdict" >&2
          exit 1
          ;;
      esac
    done <<< "$bad"

    if [ -n "$consecutive" ]; then
      echo "[probe] sources with two consecutive error snapshots:$consecutive" >&2
      exit 1
    fi

    exit 0
  '';
}
