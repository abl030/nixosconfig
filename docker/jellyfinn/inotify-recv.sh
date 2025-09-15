#!/bin/sh
# Music-only receiver: always tickle /data/music/New2 with a 'refresh' file

set -eu

# Read the UDP datagram (we don't care what it says, but log it)
payload="$(cat | tr -d '\r\n')"
echo "[receiver] recv: ${payload:-<empty>}"

# Only react to music paths; ignore everything else
case "$payload" in
    /data/music/* | /data/Music/*) ;;
    *)
        echo "[receiver] ignore (non-music): $payload"
        exit 0
        ;;
esac

# Fixed target (capital N)
TARGET="${TARGET_TICKLE:-/data/music/New2}"

# Must be a writable directory
if [ ! -d "$TARGET" ] || [ ! -w "$TARGET" ]; then
    echo "[receiver] target not a writable dir: $TARGET"
    exit 0
fi

# Debounce per-target via a lock in /tmp
key="$(printf '%s' "$TARGET" | md5sum | awk '{print $1}')"
lock="/tmp/refresh-$key.lock"

if mkdir "$lock" 2>/dev/null; then
    marker="$TARGET/refresh"
    # Create or truncate the plain 'refresh' file to trigger inotify
    if : >"$marker" 2>/dev/null; then
        echo "[receiver] refresh touched: $marker (will delete in 30s)"
        (
            sleep 30
            rm -f "$marker"
            rmdir "$lock" 2>/dev/null || true
            echo "[receiver] refresh removed: $marker"
        ) &
    else
        echo "[receiver] create/truncate failed: $marker"
        rmdir "$lock" 2>/dev/null || true
    fi
else
    echo "[receiver] refresh already pending for $TARGET"
fi
