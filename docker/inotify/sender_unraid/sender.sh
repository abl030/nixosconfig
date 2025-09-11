#!/usr/bin/env bash
set -euo pipefail

# Comma-separated container paths to watch (must match your volume mounts)
WATCH_DIRS="${WATCH_DIRS:-/watch}"
# Comma-separated receivers: host or host:port
REMOTE_HOSTS="${REMOTE_HOSTS:-receiver}"
DEFAULT_PORT="${REMOTE_PORT:-9999}"
# Map /watch -> /data so receivers share the same canonical path
SRC_PREFIX="${SRC_PREFIX:-/watch}"
DST_PREFIX="${DST_PREFIX:-/data}"
# Debounce window
DEBOUNCE_SECS="${DEBOUNCE_SECS:-5}"

# IMPORTANT: name used by receiver; we ignore events on these files to avoid loops
PING_PREFIX=".inotify-ping"

IFS=',' read -r -a DIRS <<<"$WATCH_DIRS"
IFS=',' read -r -a HOSTS <<<"$REMOTE_HOSTS"
for d in "${DIRS[@]}"; do
    [[ -d "$d" ]] || {
        echo "[sender] missing WATCH_DIR: $d" >&2
        exit 1
    }
done

echo "[sender] watching: ${DIRS[*]}"
echo "[sender] receivers: ${HOSTS[*]}  (default port: ${DEFAULT_PORT})"
echo "[sender] map: $SRC_PREFIX -> $DST_PREFIX; debounce: ${DEBOUNCE_SECS}s"
echo "[sender] ignoring files with prefix: $PING_PREFIX"

send_line() {
    local path="$1"
    for rx in "${HOSTS[@]}"; do
        local host port
        if [[ "$rx" == *:* ]]; then
            host="${rx%:*}"
            port="${rx##*:}"
        else
            host="$rx"
            port="$DEFAULT_PORT"
        fi
        printf '%s\n' "$path" | nc -u -w1 "$host" "$port" || true
    done
}

# Build inotify args once
args=(-mr -e close_write,create,move,delete --format '%w|%f|%e')
for d in "${DIRS[@]}"; do args+=("$d"); done

tmpq=$(mktemp)
trap 'rm -f "$tmpq"' EXIT

# Flusher (debounce)
(
    while true; do
        sleep "$DEBOUNCE_SECS"
        [[ -s "$tmpq" ]] || continue
        mapfile -t PATHS < <(sort -u "$tmpq")
        : >"$tmpq"
        for p in "${PATHS[@]}"; do send_line "$p"; done
    done
) &

# Collector: parse DIR|FILE|EVENTS; ignore our own ping files; enqueue directory paths only
inotifywait "${args[@]}" | while IFS='|' read -r DIR FILE EV; do
    # normalize DIR to have trailing slash removed
    DIR="${DIR%/}/"

    # ignore our own temp ping files (create+delete)
    if [[ -n "$FILE" && "$FILE" == ${PING_PREFIX}* ]]; then
        # echo "[sender] skip self-ping: $DIR$FILE"
        continue
    fi

    # decide which directory to enqueue
    # - if event is on a directory (ISDIR), the full dir is DIR+FILE
    # - otherwise (file event), we enqueue the parent DIR
    if [[ "$EV" == *ISDIR* && -n "$FILE" ]]; then
        OUTDIR="${DIR}${FILE}/"
    else
        OUTDIR="$DIR"
    fi

    # map /watch -> /data and strip duplicate slashes
    MAPPED="${OUTDIR/$SRC_PREFIX/$DST_PREFIX}"
    # remove trailing slash for cleaner logs; receiver accepts both
    MAPPED="${MAPPED%/}"

    echo "$MAPPED" >>"$tmpq"
done
