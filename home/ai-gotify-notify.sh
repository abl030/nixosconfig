#!/usr/bin/env bash
# Send deliberately low-noise AI attention/completion events to Gotify.
# Hook failures must never interrupt Claude Code or Codex.

mode="${1:-}"
agent="${2:-AI agent}"
payload=""

case "$mode" in
  claude-request|codex-permission)
    # Hook payloads are small JSON objects. Bound consumption so a malformed or
    # hostile producer cannot make the notifier buffer unbounded input.
    payload="$(dd bs=65536 count=1 2>/dev/null)"
    ;;
  codex-notify)
    payload="${2:0:65536}"
    ;;
esac

json_field() {
  printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null
}

cwd="$(json_field '.cwd')"
[ -n "$cwd" ] || cwd="$PWD"
project="$(basename -- "$cwd")"
[ -n "$project" ] || project="unknown project"
kind=""

case "$mode" in
  complete)
    kind="complete"
    title="🤖 $agent finished — $project"
    printf -v message '%s completed a meaningful work arc and is ready for review.\nProject: %s' "$agent" "$project"
    ;;
  input)
    kind="input"
    title="🤖 $agent needs input — $project"
    printf -v message '%s is blocked on a decision or information from you.\nProject: %s' "$agent" "$project"
    ;;
  claude-request)
    agent="Claude"
    kind="input"
    title="🤖 Claude needs input — $project"
    printf -v message 'Claude is waiting for approval or requested information.\nProject: %s' "$project"
    ;;
  codex-permission)
    agent="Codex"
    kind="input"
    title="🤖 Codex needs input — $project"
    printf -v message 'Codex is waiting for approval.\nProject: %s' "$project"
    ;;
  codex-notify)
    [ "$(json_field '.type')" = "agent-turn-complete" ] || exit 0
    final_message="$(json_field '."last-assistant-message"')"
    kind="$(
      jq -nr \
        --arg text "$final_message" \
        --arg complete '<!-- ai-gotify:complete -->' \
        --arg input '<!-- ai-gotify:input -->' \
        'if ($text | endswith($complete))
            and (($text | split($complete) | length) == 2)
            and (($text | split($input) | length) == 1)
         then "complete"
         elif ($text | endswith($input))
            and (($text | split($input) | length) == 2)
            and (($text | split($complete) | length) == 1)
         then "input"
         else empty
         end' 2>/dev/null
    )"
    [ -n "$kind" ] || exit 0
    agent="Codex"
    if [ "$kind" = "input" ]; then
      title="🤖 Codex needs input — $project"
      printf -v message 'Codex is blocked on a decision or information from you.\nProject: %s' "$project"
    else
      title="🤖 Codex finished — $project"
      printf -v message 'Codex completed a meaningful work arc and is ready for review.\nProject: %s' "$project"
    fi
    ;;
  publish)
    kind="${2:-}"
    agent="${3:-AI agent}"
    project="${4:-unknown project}"
    case "$kind" in
      input)
        title="🤖 $agent needs input — $project"
        printf -v message '%s is blocked on a decision or information from you.\nProject: %s' "$agent" "$project"
        ;;
      complete)
        title="🤖 $agent finished — $project"
        printf -v message '%s completed a meaningful work arc and is ready for review.\nProject: %s' "$agent" "$project"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Test seam: exercise all parsing/routing without publishing or reading secrets.
if [ "${AI_GOTIFY_TEST_MODE:-}" = "1" ] &&
  case "${AI_GOTIFY_CAPTURE_FILE:-}" in /tmp/ai-gotify-notify-test-*) true ;; *) false ;; esac; then
  jq -nc \
    --arg kind "$kind" \
    --arg agent "$agent" \
    --arg project "$project" \
    --arg cwd "$cwd" \
    --arg title "$title" \
    --arg message "$message" \
    '{kind: $kind, agent: $agent, project: $project, cwd: $cwd, title: $title, message: $message}' \
    >>"$AI_GOTIFY_CAPTURE_FILE" 2>/dev/null
  exit 0
fi

# Keep client hooks and explicit agent calls non-blocking. The transient user
# unit performs delivery after this process exits; only sanitized labels cross
# the process boundary, never the credential or arbitrary model text.
if [ "$mode" != "publish" ]; then
  systemd-run --user --quiet --collect --service-type=exec \
    "$0" publish "$kind" "$agent" "$project" >/dev/null 2>&1 || true
  exit 0
fi

url="https://gotify.ablz.au"
token_file="/run/secrets/gotify/token"
priority="5"
[ -r "$token_file" ] || exit 0

raw_token="$(cat "$token_file" 2>/dev/null)"
case "$raw_token" in GOTIFY_TOKEN=*) token="${raw_token#GOTIFY_TOKEN=}" ;; *) token="$raw_token" ;; esac
token="$(printf '%s' "$token" | tr -d '\r\n')"
[ -n "$token" ] || exit 0

printf 'header = "X-Gotify-Key: %s"\n' "$token" | \
  env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
    -u CURL_CA_BUNDLE -u SSL_CERT_FILE -u SSL_CERT_DIR -u SSLKEYLOGFILE \
    curl -q --config - --proto '=https' --connect-timeout 3 --max-time 8 -fsS -X POST \
    --form-string "title=$title" \
    --form-string "message=$message" \
    --form-string "priority=$priority" \
    --url "$url/message" >/dev/null 2>&1 || true

exit 0
