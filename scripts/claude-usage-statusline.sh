# Claude Code status line + subscription-limit ledger.
# Reads the status-line JSON on stdin, prints a one-line status, and appends a
# numeric-only record to ~/.local/state/claude-usage/limits.jsonl (and journald,
# tag claude-usage) whenever the 5h/weekly percentage moves or this session's
# API-equivalent cost grows by >= $1. Never records cwd, paths or prompt text.
# See docs/wiki/claude-code/usage-limit-ledger.md.

input=$(cat)

# \x1f separator: a whitespace IFS (tab) would collapse empty fields and shift
# every later value when a limit window is absent.
IFS=$'\x1f' read -r sid model_id model_name cost fh fh_reset sd sd_reset ctx_used ctx_size ctx_pct \
  pc_warm pc_ttl pc_exp < <(
  jq -r '[
      (.session_id // "unknown"),
      (.model.id // ""),
      (.model.display_name // .model.id // "claude"),
      (.cost.total_cost_usd // 0),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.context_window.total_input_tokens // ""),
      (.context_window.context_window_size // ""),
      (.context_window.used_percentage // ""),
      (.prompt_cache.warm | if . == null then "" else tostring end),
      (.prompt_cache.ttl // ""),
      (.prompt_cache.expires_at // "")
    ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null ||
    printf 'unknown\x1f\x1fclaude\x1f0\x1f\x1f\x1f\x1f\x1f\x1f\x1f\x1f\x1f\x1f\n'
)
[[ $cost =~ ^[0-9.]+$ ]] || cost=0
[[ $ctx_used =~ ^[0-9]+$ ]] || ctx_used=""
[[ $ctx_size =~ ^[0-9]+$ ]] || ctx_size=""

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
# Context: tokens in the current window (last request's input incl. cache).
fmt_tok() { awk -v n="$1" 'BEGIN { if (n >= 1000000) printf (n % 1000000 ? "%.1fM" : "%dM"), n / 1000000; else printf "%dk", n / 1000 }'; }
ctx=""
if [ -n "$ctx_used" ]; then
  ctx="ctx $(fmt_tok "$ctx_used")"
  [ -n "$ctx_size" ] && ctx="$ctx/$(fmt_tok "$ctx_size")"
  if [ -n "$ctx_pct" ]; then
    ctx="$ctx ($(fmt_pct "$ctx_pct"))"
  elif [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ]; then
    ctx="$ctx ($((ctx_used * 100 / ctx_size))%)"
  fi
fi
# Prompt cache: time left while warm; once expired, what the next message costs
# to re-cache the whole context (input price x write multiplier: 2x for the 1h
# cache, 1.25x for 5m), as API $ and share of the week. Claude Code refreshes
# the status line at expires_at, so this flips to cold on time.
cache=""
if [ "$pc_warm" = "true" ] && [[ $pc_exp =~ ^[0-9]+$ ]]; then
  left=$(((pc_exp - $(date +%s)) / 60))
  [ "$left" -ge 0 ] && cache="cache ${left}m"
elif [ "$pc_warm" = "false" ] && [ -n "$ctx_used" ] && [ "$ctx_used" -gt 0 ]; then
  case "$model_id" in
    claude-opus-5-5*) in_price=4 ;;
    claude-sonnet-5*) in_price=2 ;;
    claude-haiku-5-5*) in_price=0.1 ;;
    claude-fable-5* | claude-mythos-5*) in_price=10 ;;
    claude-opus-5* | claude-opus-4*) in_price=5 ;;
    claude-haiku-4*) in_price=1 ;;
    *) in_price=4 ;;
  esac
  mult=1.25
  [ "$pc_ttl" = "1h" ] && mult=2
  cache=$(awk -v t="$ctx_used" -v p="$in_price" -v m="$mult" -v u="$usd_per_pct" \
    'BEGIN { c = t / 1e6 * p * m; printf "cold: next ≈%.2f%% wk ($%.2f)", (u > 0 ? c / u : 0), c }')
fi
head="$model_name${ctx:+ · $ctx}${cache:+ · $cache}"
if [ -n "$fh$sd" ]; then
  line="$head · 5h $(fmt_pct "$fh") · wk $(fmt_pct "$sd")"
  if [ -n "$sd_reset" ]; then
    line="$line ($(date -d "@${sd_reset%.*}" '+%a %H:%M' 2>/dev/null || true))"
  fi
  line="$line · $chat"
else
  line="$head · $chat"
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
