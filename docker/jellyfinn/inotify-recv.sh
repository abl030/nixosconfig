#!/bin/sh
# reads one UDP datagram from stdin, triggers a self-cleaning ping
dir="$(cat | tr -d '\r')"
echo "[receiver] recv: $dir"

case "$dir" in
    /data/*) ;;
    *)
        echo "[receiver] reject: $dir"
        exit 0
        ;;
esac

if [ -d "$dir" ] && [ -w "$dir" ]; then
    f="$(mktemp -p "$dir" ".inotify-ping.XXXXXX")" || {
        echo "[receiver] mktemp failed in $dir"
        exit 0
    }
    rm -f -- "$f" || true
    echo "[receiver] pinged: $dir"
else
    echo "[receiver] not writable: $dir"
fi
