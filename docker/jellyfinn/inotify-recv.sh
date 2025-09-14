#!/bin/sh
# Reads one UDP datagram from stdin: absolute dir under /data
dir="$(cat | tr -d '\r\n')"
echo "[receiver] recv: $dir"

case "$dir" in
    /data/*) ;;
    *)
        echo "[receiver] reject: $dir"
        exit 0
        ;;
esac

# Must be a writable directory
if [ -d "$dir" ] && [ -w "$dir" ]; then
    # One refresh per dir at a time: lock lives in /tmp so it won't trigger senders
    key="$(printf '%s' "$dir" | md5sum | awk '{print $1}')"
    lock="/tmp/refresh-$key.lock"

    if mkdir "$lock" 2>/dev/null; then
        # Create the refresh file, then remove it after 46s
        if touch "$dir/refresh"; then
            echo "[receiver] refresh touched: $dir/refresh (will delete in 46s)"
            (
                sleep 46
                rm -f "$dir/refresh"
                rmdir "$lock" 2>/dev/null || true
                echo "[receiver] refresh removed: $dir/refresh"
            ) &
        else
            echo "[receiver] touch failed in $dir"
            rmdir "$lock" 2>/dev/null || true
        fi
    else
        echo "[receiver] refresh already pending for $dir"
    fi
else
    echo "[receiver] not writable or not a dir: $dir"
fi
