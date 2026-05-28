#!/data/data/com.termux/files/usr/bin/sh
set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice-input"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-voice-input"
LOCK_DIR="$STATE_DIR/lock"
STATE_FILE="$STATE_DIR/current-recording"
LAST_TRANSCRIPT="$STATE_DIR/last-transcript.txt"

if [ ! -r "$CONFIG_FILE" ]; then
  echo "missing config: $CONFIG_FILE" >&2
  exit 78
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${DOC1_SSH:=doc1}"
: "${TMUX_TARGET:?missing TMUX_TARGET in $CONFIG_FILE}"
: "${REMOTE_INJECT:=~/.local/bin/agent-voice-inject}"
: "${WHISPER_URL:=https://whisper.ablz.au/v1/audio/transcriptions}"
: "${WHISPER_MODEL:=large}"
: "${MAX_SECONDS:=45}"
: "${AUDIO_ENCODER:=aac}"
: "${AUDIO_EXT:=m4a}"
: "${AUDIO_RATE:=16000}"
: "${AUDIO_CHANNELS:=1}"

mkdir -p "$STATE_DIR"

cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "agent voice input is already running" >&2
  exit 75
fi
trap cleanup_lock EXIT INT TERM

have() {
  command -v "$1" >/dev/null 2>&1
}

notify() {
  msg="$1"
  echo "$msg" >&2
  if have termux-vibrate; then
    termux-vibrate -d 120 >/dev/null 2>&1 || true
  fi
  if have termux-notification; then
    termux-notification --id agent-voice-input --title "Agent voice" --content "$msg" >/dev/null 2>&1 || true
  fi
}

need() {
  if ! have "$1"; then
    notify "Missing command: $1"
    exit 127
  fi
}

need termux-microphone-record
need curl
need jq
need ssh

start_recording() {
  ts=$(date +%Y%m%d-%H%M%S)
  audio="$STATE_DIR/recording-$ts.$AUDIO_EXT"
  err="$STATE_DIR/start-error.txt"

  if ! termux-microphone-record \
    -f "$audio" \
    -l "$MAX_SECONDS" \
    -e "$AUDIO_ENCODER" \
    -r "$AUDIO_RATE" \
    -c "$AUDIO_CHANNELS" >"$err" 2>&1; then
    if grep -q 'RECORD_AUDIO' "$err" 2>/dev/null; then
      notify "Grant Termux:API mic permission"
    else
      notify "Could not start recording"
    fi
    rm -f "$STATE_FILE"
    exit 1
  fi

  if grep -q 'RECORD_AUDIO' "$err" 2>/dev/null; then
    notify "Grant Termux:API mic permission"
    rm -f "$STATE_FILE"
    exit 1
  fi

  termux-microphone-record -i >"$err" 2>&1 || true
  if grep -q 'RECORD_AUDIO' "$err" 2>/dev/null; then
    notify "Grant Termux:API mic permission"
    termux-microphone-record -q >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
    exit 1
  fi

  rm -f "$err"
  printf '%s\n' "$audio" >"$STATE_FILE"
  notify "Recording"
}

stop_recording() {
  audio=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)
  rm -f "$STATE_FILE"

  if [ -z "$audio" ]; then
    notify "No recording state"
    exit 1
  fi

  termux-microphone-record -q >/dev/null 2>&1 || true
  sleep 1

  if [ ! -s "$audio" ]; then
    notify "Recording was empty"
    exit 1
  fi

  notify "Transcribing"
  response=$(
    curl -fsS --max-time 180 \
      -X POST "$WHISPER_URL" \
      -F "file=@$audio" \
      -F "model=$WHISPER_MODEL" \
      -F "response_format=json"
  ) || {
    notify "Whisper failed"
    exit 1
  }

  text=$(printf '%s' "$response" | jq -r '.text // empty' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  printf '%s\n' "$text" >"$LAST_TRANSCRIPT"

  if [ -z "$text" ]; then
    notify "No speech detected"
    exit 65
  fi

  # Values come from the setup-generated config; expansion must happen on the
  # phone before ssh builds the remote command.
  # shellcheck disable=SC2029
  if ! printf '%s\n' "$text" | ssh "$DOC1_SSH" "$REMOTE_INJECT" "$TMUX_TARGET"; then
    notify "Injection failed"
    exit 1
  fi

  notify "Sent"
}

if [ -f "$STATE_FILE" ]; then
  stop_recording
else
  start_recording
fi
