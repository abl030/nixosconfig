#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: agent-voice-detect-tmux.sh [--shell|--plain]

Detect the tmux pane that owns the current agent process.

  --shell  emit shell assignments for setup scripts
  --plain  emit a short human-readable summary (default)
EOF
}

mode=plain
case "${1:-}" in
  --shell) mode=shell ;;
  --plain | "") mode=plain ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
esac

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed or not on PATH" >&2
  exit 127
fi

if [ -z "${TMUX:-}" ]; then
  echo "this shell is not inside tmux; handsfree input needs an active tmux pane" >&2
  echo "candidate panes:" >&2
  tmux list-panes -a -F '  #{session_name}:#{window_index}.#{pane_index} #{pane_tty} #{pane_current_command} #{pane_title}' 2>/dev/null >&2 || true
  exit 2
fi

target=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
tty=$(tmux display-message -p '#{pane_tty}')
command=$(tmux display-message -p '#{pane_current_command}')
title=$(tmux display-message -p '#{pane_title}')

case "$mode" in
  shell)
    printf 'AGENT_VOICE_TMUX_TARGET=%q\n' "$target"
    printf 'AGENT_VOICE_TMUX_TTY=%q\n' "$tty"
    printf 'AGENT_VOICE_TMUX_COMMAND=%q\n' "$command"
    printf 'AGENT_VOICE_TMUX_TITLE=%q\n' "$title"
    ;;
  plain)
    printf 'target=%s tty=%s command=%s title=%s\n' "$target" "$tty" "$command" "$title"
    ;;
esac
