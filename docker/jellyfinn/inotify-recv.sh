#!/bin/sh
# Unified receiver:
# - Tickles the actual target directory for all library types.
# - For MUSIC events, also dynamically tickles the top-level source directory
#   (e.g., an event in /data/music/new/artist/album also tickles /data/music/new).
# - Creates 'refresh' (plain file) and deletes it after 46s.
# - Debounces per-target via /tmp lock.
# - Ignores library roots to avoid full-library refreshes.

set -eu

# --- config (override via environment if you like) ---------------------
ROOT_MOVIES="${ROOT_MOVIES:-/data/movies}"
ROOT_TV="${ROOT_TV:-/data/tv}"
ROOT_MUSIC="${ROOT_MUSIC:-/data/music}"

MARKER_NAME="${MARKER_NAME:-refresh}" # plain file
TTL="${TTL:-46}"                      # seconds
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
        # 1. Normal tickle on the actual target path
        tickle "$target"

        # 2. Dynamically determine and tickle the top-level source directory
        #    (e.g., /data/music/new). This removes the old hardcoded path.

        # Get path relative to music root (e.g., /data/music/new/artist -> /new/artist)
        relative_path="${target#$ROOT_MUSIC}"

        # Proceed only if it's not the root itself
        if [ -n "$relative_path" ]; then
            # Strip leading slash (e.g., /new/artist -> new/artist)
            relative_path="${relative_path#/}"

            # Get the first directory component (e.g., new/artist -> new)
            top_level_dir="${relative_path%%/*}"

            if [ -n "$top_level_dir" ]; then
                source_tickle_path="$ROOT_MUSIC/$top_level_dir"

                # Tickle the source path, but only if it's not the same as the original target
                if [ "$source_tickle_path" != "$target" ]; then
                    tickle "$source_tickle_path"
                fi
            fi
        fi
        ;;
    *)
        log "[receiver] ignore (not in movies/tv/music roots): $target"
        ;;
esac
