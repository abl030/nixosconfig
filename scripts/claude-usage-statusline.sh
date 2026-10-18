# Claude Code status line + subscription-limit ledger.
# Reads the status-line JSON on stdin, prints a one-line status, and appends a
# numeric-only record to ~/.local/state/claude-usage/limits.jsonl (and journald,
# tag claude-usage) whenever the 5h/weekly percentage moves or this session's
# API-equivalent cost grows by >= $1. Never records cwd, paths or prompt text.
# See docs/wiki/claude-code/usage-limit-ledger.md.

input=$(cat)

# \x1f separator: a whitespace IFS (tab) would collapse empty fields and shift
# every later value when a limit window is absent.
IFS=$'\x1f' read -r sid model_id model_name cost fh fh_reset sd sd_reset < <(
  jq -r '[
      (.session_id // "unknown"),
      (.model.id // ""),
      (.model.display_name // .model.id // "claude"),
      (.cost.total_cost_usd // 0),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // "")
    ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null ||
    printf 'unknown\x1f\x1fclaude\x1f0\x1f\x1f\x1f\x1f\n'
)
[[ $cost =~ ^[0-9.]+$ ]] || cost=0

state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-usage"

# --- status line ------------------------------------------------------------
# 5h/wk are account-wide. "chat" is this session's API-equivalent cost and its
# estimated share of the week: cost / (API $ per 1% of the weekly limit).
# Default 11.5 is the Max 5x calibration of 2026-10-17; override by writing a
# number to $state/usd-per-weekly-pct (e.g. after a plan change).
fmt_pct() { [ -n "$1" ] && printf '%.0f%%' "$1" || printf '–'; }
usd_per_pct=$(cat "$state/usd-per-weekly-pct" 2>/dev/null || true)
[[ $usd_per_pct =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd_per_pct=11.5
chat="chat \$$(printf '%.2f' "$cost") ≈$(awk -v c="$cost" -v u="$usd_per_pct" 'BEGIN { printf "%.1f", (u > 0 ? c / u : 0) }')% wk"
if [ -n "$fh$sd" ]; then
  line="$model_name · 5h $(fmt_pct "$fh") · wk $(fmt_pct "$sd")"
  if [ -n "$sd_reset" ]; then
    line="$line ($(date -d "@${sd_reset%.*}" '+%a %H:%M' 2>/dev/null || true))"
  fi
  line="$line · $chat"
else
  line="$model_name · $chat"
fi
printf '%s\n' "$line"

# --- ledger (best effort, never blocks or fails the status line) -----------
{
  umask 077
  mkdir -p "$state/sessions"
  exec 9>"$state/.lock"
  flock -n 9 || exit 0

  limits="$fh|$fh_reset|$sd|$sd_reset"
  last_limits=$(cat "$state/last-limits" 2>/dev/null || true)
  safe_sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
  last_cost=$(cat "$state/sessions/$safe_sid" 2>/dev/null || echo 0)

  reason=""
  if [ -n "$fh$sd" ] && [ "$limits" != "$last_limits" ]; then
    reason="limits"
  elif awk -v c="$cost" -v l="$last_cost" 'BEGIN { exit !(c - l >= 1) }'; then
    reason="cost"
  fi
  [ -n "$reason" ] || exit 0

  record=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(uname -n)" \
    --arg sid "$sid" --arg model "$model_id" --arg reason "$reason" \
    --arg cost "$cost" --arg fh "$fh" --arg fhr "$fh_reset" --arg sd "$sd" --arg sdr "$sd_reset" '
      def num: if . == "" then null else tonumber end;
      {ts: $ts, host: $host, sid: $sid, model: $model, reason: $reason,
       cost_usd: ($cost | num), five_hour: ($fh | num), five_hour_resets: ($fhr | num),
       seven_day: ($sd | num), seven_day_resets: ($sdr | num)}')

  printf '%s\n' "$record" >>"$state/limits.jsonl"
  logger -t claude-usage -- "$record" 2>/dev/null || true
  printf '%s' "$limits" >"$state/last-limits"
  printf '%s' "$cost" >"$state/sessions/$safe_sid"
  find "$state/sessions" -type f -mtime +14 -delete 2>/dev/null || true
} 2>/dev/null || true
