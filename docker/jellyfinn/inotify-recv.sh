#!/bin/sh
# Unified receiver:
# - Always tickle /data/music/New2 for MUSIC events (Jelly test path)
# - Also tickle the actual target directory ("normal") for all 3 libs
# - Creates 'refresh' (plain file) and deletes it after 46s
# - Debounces per-target via /tmp lock
# - Ignores library roots to avoid full-library refreshes

set -eu

# --- config (override via environment if you like) ---------------------
ROOT_MOVIES="${ROOT_MOVIES:-/data/movies}"
ROOT_TV="${ROOT_TV:-/data/tvshows}"
ROOT_MUSIC="${ROOT_MUSIC:-/data/music}"

JELLY_TEST_MUSIC="${TARGET_TICKLE_JELLY_MUSIC:-/data/music/New2}" # capital N
MARKER_NAME="${MARKER_NAME:-refresh}"                             # plain file
TTL="${TTL:-46}"                                                  # seconds
# ----------------------------------------------------------------------

log() { printf '%s\n' "$*"; }

# Read UDP datagram
payload="$(cat | tr -d '\r\n')"
log "[receiver] recv: ${payload:-<empty>}"

# Accept only /data/*
case "$payload" in
/data/*) ;;
*)
  log "[receiver] reject (outside /data): $payload"
  exit 0
  ;;
esac

# If payload isn’t a dir, resolve to its parent
target="$payload"
if [ ! -d "$target" ]; then
  target="$(dirname -- "$target" 2>/dev/null || echo "$payload")"
fi

# Canonicalize double slashes / trailing slashes
# (leave as-is otherwise; POSIX sh)
case "$target" in
*/) target="${target%/}" ;;
esac

# Helper: lowercase prefix check for root matching
starts_with() {
  case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac
}

# Identify which library
lib="other"
case "$target" in
"$ROOT_MOVIES"/* | "$ROOT_MOVIES") lib="movies" ;;
"$ROOT_TV"/* | "$ROOT_TV") lib="tvshows" ;;
"$ROOT_MUSIC"/* | "$ROOT_MUSIC") lib="music" ;;
esac

# Don’t ever tickle the library root dirs themselves
is_library_root() {
  case "$1" in
  "$ROOT_MOVIES" | "$ROOT_TV" | "$ROOT_MUSIC") return 0 ;;
  *) return 1 ;;
  esac
}

# Core tickle: create a 'refresh' marker file and delete later
tickle() {
  t="$1"
  [ -z "$t" ] && return 0
  if is_library_root "$t"; then
    log "[receiver] skip (library root): $t"
    return 0
  fi
  if [ ! -d "$t" ] || [ ! -w "$t" ]; then
    log "[receiver] not writable or not a dir: $t"
    return 0
  fi

  key="$(printf '%s' "$t" | md5sum | awk '{print $1}')"
  lock="/tmp/refresh-$key.lock"

  if mkdir "$lock" 2>/dev/null; then
    marker="$t/$MARKER_NAME"
    # Creation/truncate; no utime syscall (avoids noisy permission errors)
    if : >"$marker" 2>/dev/null; then
      log "[receiver] refresh touched: $marker (will delete in ${TTL}s)"
      (
        sleep "$TTL"
        rm -f "$marker"
        rmdir "$lock" 2>/dev/null || true
        log "[receiver] refresh removed: $marker"
      ) &
    else
      log "[receiver] create/truncate failed: $marker"
      rmdir "$lock" 2>/dev/null || true
    fi
  else
    log "[receiver] refresh already pending for $t"
  fi
}

# --- Apply rules -------------------------------------------------------

case "$lib" in
movies | tvshows)
  # Normal tickle in the actual path
  tickle "$target"
  ;;
music)
  # Normal tickle in the actual path…
  tickle "$target"
  # …and keep the Jelly test tickle to /data/music/New2
  tickle "$JELLY_TEST_MUSIC"
  ;;
*)
  log "[receiver] ignore (not in movies/tvshows/music roots): $target"
  ;;
esac
