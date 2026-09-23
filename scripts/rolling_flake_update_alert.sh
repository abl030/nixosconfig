# Direct Gotify pages for the rolling flake update, independent of Hermes RCA.
#
#   failure  OnFailure= of rolling-flake-update.service. Pages every failed run
#            (group failure, abort, timeout, kill). A run that still pushed
#            (fresh heartbeat) pages low (prio 6) and resets the streak;
#            otherwise it counts consecutive failures (prio 8, then 10). The
#            updater also resets the streak after a fully green run.
#   stale    Daily timer. Pages when master's signed heartbeat is older than
#            RFU_ALERT_STALE_HOURS and no failure page went out in the last 20h,
#            i.e. the updater is not running at all.
#
# Before 2026-09-23 a timeout kill sent nothing and the staleness page had been
# retired, so the updater failed for 11 nights with 3 low-priority pings.
# See docs/wiki/infrastructure/rolling-flake-update.md.
set -euo pipefail

mode="${1:?usage: rolling-flake-update-alert failure|stale}"
state="${RFU_STATE_DIR:?}"
streak_file="$state/failure-streak"
alerted_file="$state/last-failure-alert"
stale_hours="${RFU_ALERT_STALE_HOURS:-36}"
now="$(date +%s)"

send() {
  local title="$1" message="$2" priority="$3" token header
  token="$(sed -n 's/^GOTIFY_TOKEN=//p; /^[^=]*$/p' "${GOTIFY_TOKEN_FILE:?}" | head -n1)"
  [ -n "$token" ] || { echo "empty Gotify token" >&2; return 1; }
  # Keep the token out of argv: curl reads the header from a private file.
  header="$(mktemp)"
  chmod 600 "$header"
  printf 'X-Gotify-Key: %s\n' "$token" >"$header"
  local rc=0
  jq -n --arg title "$title" --arg message "$message" --argjson priority "$priority" \
    '{title: $title, message: $message, priority: $priority,
      extras: {"client::display": {contentType: "text/markdown"}}}' |
    curl -fsS --connect-timeout 5 --max-time 20 -H "@$header" \
      -H "Content-Type: application/json" --data-binary @- \
      "${GOTIFY_URL:?}/message" >/dev/null || rc=$?
  rm -f "$header"
  return "$rc"
}

# Age of the last fully-completed run, from master's signed heartbeat.
hb_epoch="$(curl -fsS --connect-timeout 5 --max-time 20 "${RFU_HEARTBEAT_URL:?}" | jq -r '.epoch // empty' 2>/dev/null || true)"
if [[ "$hb_epoch" =~ ^[0-9]+$ ]]; then
  age_hours=$(((now - hb_epoch) / 3600))
  since="last successful run $(TZ=Australia/Perth date -d "@$hb_epoch" '+%a %d %b %H:%M') ($((age_hours / 24))d $((age_hours % 24))h ago)"
else
  age_hours=""
  since="heartbeat unreadable at ${RFU_HEARTBEAT_URL}"
fi

case "$mode" in
  failure)
    result="$(systemctl show -p Result --value rolling-flake-update.service 2>/dev/null || echo unknown)"
    lines="$(journalctl -u rolling-flake-update.service -n 2000 -o cat --no-pager 2>/dev/null |
      grep -F '[nix-rolling]' | sed 's/^\[nix-rolling\] //' | grep -E '^(✅|❌|➖)' | tail -n 12 || true)"
    # A fresh heartbeat means this run pushed: some groups landed and only
    # the failed ones wait. Not an outage, so reset the streak and page low.
    if [ -n "$age_hours" ] && [ "$age_hours" -lt 3 ]; then
      echo 0 >"$streak_file"
      # shellcheck disable=SC2016  # literal Markdown code fence
      message="$(printf 'The update landed, but some groups failed and were held back (result: %s). A Hermes RCA may follow.\n\n```\n%s\n```' \
        "$result" "$lines")"
      send "🟡 Rolling flake update landed; a group failed" "$message" 6
      echo "$now" >"$alerted_file"
      echo "paged: partial failure priority=6"
      exit 0
    fi
    streak=$(($(cat "$streak_file" 2>/dev/null || echo 0) + 1))
    echo "$streak" >"$streak_file"
    priority=8
    [ "$streak" -ge 2 ] && priority=10
    lines="$(journalctl -u rolling-flake-update.service -n 2000 -o cat --no-pager 2>/dev/null |
      grep -F '[nix-rolling]' | tail -n 12 | sed 's/^\[nix-rolling\] //' || true)"
    # shellcheck disable=SC2016  # literal Markdown code fence
    message="$(printf '**%s failed run(s) in a row** (result: %s); %s.\n\nHosts are not getting package updates until a run completes. A Hermes RCA may follow.\n\n```\n%s\n```' \
      "$streak" "$result" "$since" "$lines")"
    send "🔴 Rolling flake update failed — night $streak" "$message" "$priority"
    echo "$now" >"$alerted_file"
    echo "paged: failure streak=$streak priority=$priority"
    ;;
  stale)
    if [ -z "$age_hours" ]; then
      send "⚠️ Fleet update freshness unknown" "Could not read the rolling-update heartbeat: $since." 8
      exit 0
    fi
    if [ "$age_hours" -lt "$stale_hours" ]; then
      echo "fresh: heartbeat ${age_hours}h old"
      exit 0
    fi
    last_alert="$(cat "$alerted_file" 2>/dev/null || echo 0)"
    if [ $((now - last_alert)) -lt $((20 * 3600)) ]; then
      echo "stale (${age_hours}h) but a failure page went out recently; not repeating"
      exit 0
    fi
    priority=8
    [ "$age_hours" -ge 72 ] && priority=10
    send "⚠️ Fleet package updates stale — $((age_hours / 24)) days" \
      "No rolling flake update has completed: $since. The updater may not be running (timer, unit or host problem). Check \`systemctl status rolling-flake-update\` on doc1." \
      "$priority"
    echo "paged: stale ${age_hours}h priority=$priority"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
