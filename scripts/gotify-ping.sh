#!/usr/bin/env bash
set -euo pipefail

url="${GOTIFY_URL:-https://gotify.ablz.au}"
token_file="${GOTIFY_TOKEN_FILE:-/run/secrets/gotify/token}"
priority="${GOTIFY_PRIORITY:-5}"

title="${1:-Codex needs input}"
message="${2:-Please check the session; input requested.}"

if [[ ! -r "$token_file" ]]; then
  echo "gotify-ping: token file not readable: $token_file" >&2
  exit 1
fi

token=$(cat "$token_file")

curl -fsS -X POST \
  -F "title=$title" \
  -F "message=$message" \
  -F "priority=$priority" \
  "$url/message?token=$token" >/dev/null
