#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: agent-voice-inject.sh [--no-enter] <tmux-target>

Reads transcript text from stdin, pastes it literally into <tmux-target>,
and presses Enter unless --no-enter is supplied.
EOF
}

send_enter=1
case "${1:-}" in
  --no-enter)
    send_enter=0
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
esac

target="${1:-}"
if [ -z "$target" ]; then
  usage >&2
  exit 64
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed or not on PATH" >&2
  exit 127
fi

if [[ ! "$target" =~ ^[A-Za-z0-9_.-]+:[0-9]+[.][0-9]+$ ]]; then
  echo "refusing suspicious tmux target: $target" >&2
  exit 64
fi

if ! tmux list-panes -t "$target" >/dev/null 2>&1; then
  echo "tmux target does not exist: $target" >&2
  exit 66
fi

text=$(
  tr '\r\n\t' '   ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
)

if [ -z "$text" ]; then
  echo "empty transcript; not submitting" >&2
  exit 65
fi

buffer="agent-voice-input-$$"
printf '%s' "$text" | tmux load-buffer -b "$buffer" -
tmux paste-buffer -d -b "$buffer" -t "$target"

if [ "$send_enter" -eq 1 ]; then
  tmux send-keys -t "$target" Enter
fi

printf 'submitted %d characters to %s\n' "${#text}" "$target" >&2
