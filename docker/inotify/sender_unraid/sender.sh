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

# Names of files to ignore (comma-separated). We always want to ignore "refresh".
IGNORE_BASENAMES="${IGNORE_BASENAMES:-refresh}"

# Single heartbeat file updated by the flusher loop
HEALTH_FILE="/tmp/sender-healthy"

# Legacy ping prefix still ignored if present anywhere else
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
echo "[sender] ignoring basenames: ${IGNORE_BASENAMES}"

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
        if printf '%s\n' "$path" | nc -u -w1 "$host" "$port"; then
            echo "[sender] pinged: ${host}:${port} <- ${path}"
        else
            echo "[sender] ping FAILED: ${host}:${port} <- ${path}" >&2
        fi
    done
}

# Build inotify args once
args=(-mr -e close_write,create,move,delete --format '%w|%f|%e')
for d in "${DIRS[@]}"; do args+=("$d"); done

tmpq="$(mktemp)"
trap 'rm -f "$tmpq"' EXIT

# Initialize heartbeat so healthcheck doesn't fail on startup
date +%s >"$HEALTH_FILE"

# Flusher (debounce) + heartbeat writer
(
    while true; do
        sleep "$DEBOUNCE_SECS"
        # Heartbeat in epoch seconds (portable, no stat/find needed)
        date +%s >"$HEALTH_FILE"
        [[ -s "$tmpq" ]] || continue
        mapfile -t PATHS < <(sort -u "$tmpq")
        : >"$tmpq"
        for p in "${PATHS[@]}"; do send_line "$p"; done
    done
) &

# Collector: parse DIR|FILE|EVENTS; ignore loop-causing files; enqueue directory paths only
inotifywait "${args[@]}" | while IFS='|' read -r DIR FILE EV; do
    DIR="${DIR%/}/"

    # --- Ignore our own files to prevent loops ---
    skip=0
    if [[ -n "${FILE:-}" ]]; then
        [[ "$FILE" == ${PING_PREFIX}* ]] && skip=1
        IFS=',' read -r -a IGNS <<<"$IGNORE_BASENAMES"
        for bn in "${IGNS[@]}"; do
            [[ "$FILE" == "$bn" ]] && {
                skip=1
                break
            }
        done
    fi
    ((skip)) && continue
    # --------------------------------------------

    # decide which directory to enqueue
    if [[ "$EV" == *ISDIR* && -n "$FILE" ]]; then
        OUTDIR="${DIR}${FILE}/"
    else
        OUTDIR="$DIR"
    fi

    # map /watch -> /data and strip duplicate slashes
    MAPPED="${OUTDIR/$SRC_PREFIX/$DST_PREFIX}"
    MAPPED="${MAPPED%/}" # normalize (receiver accepts both)
    echo "$MAPPED" >>"$tmpq"
done
