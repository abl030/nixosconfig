
---

# Inotify Bridge (UDP “Tickler”) for Media Libraries

> Reliable, low-overhead change notifications from your storage box to media servers (Jellyfin, Plex, etc.), even when the server reads libraries over NFS where native inotify doesn’t propagate.

## Why this exists

* **NFS + inotify ≠ friends.** Inotify events don’t reliably propagate to NFS clients. Media servers mounted over NFS may never “see” new files.
* **APIs aren’t enough.** For some servers (notably **Jellyfin**), programmatic “refresh just this brand-new thing” isn’t always available or reliable across Movies / TV / Music.
* **Touching works.** Creating and then deleting a small “marker” file inside a directory reliably wakes up the server’s filesystem watcher.

This bridge centralizes file-change detection on your storage box and broadcasts **tiny UDP ticks** to one or more receivers running alongside your media servers. Receivers create a temporary `refresh` file in target folders to trigger scans—with smart rules for Movies/TV and Music.

---

## High-level architecture

```
[ Unraid / NAS ]                        [ Any server running a media stack ]
+--------------------+                  +-----------------------------------+
| Sender container   |   UDP :9999 ---> | Receiver container (socat + sh)   |
| - Watches paths    |  (broadcasts)    | - Validates target                |
| - Debounces        |                  | - Creates "refresh" marker        |
| - Sends absolute   |                  | - Removes marker after TTL        |
|   /data/... paths  |                  | - Per-library tickle strategy     |
+--------------------+                  +-----------------------------------+
```

* **Sender**: watches configured directories and, on changes, sends a single-line payload like `/data/movies/Inception (2010)` to all receivers.
* **Receiver**: validates the path, applies library-specific logic, creates a `refresh` file and removes it after a short delay to trigger filesystem watchers reliably.

---

## What “tickling” does (receiver rules)

Implemented in `inotify-recv.sh`:

* **Movies / TV:**

  1. Tickle the specific directory that changed **and**
  2. Tickle the **library root** (`/data/movies` or `/data/tv`) to force discovery of brand-new titles.
* **Music:**

  1. Tickle the specific path that changed **and**
  2. Also tickle the **top-level artist folder** under `/data/music` (helps Jellyfin/Plex pick up a new artist/album consistently).

Tickles create a plain file named `refresh` in the target directory, then delete it after `TTL` seconds (default **46s**). A per-directory lock in `/tmp` debounces repeated events.

---

## Quick start

### 1) Receiver (runs next to Jellyfin/Plex)

Mount your libraries into the receiver so it can touch those directories, **read/write**:

```yaml
# docker-compose.yml (receiver side)
version: "3.8"
services:
  inotify-receiver:
    image: alpine:3.20
    container_name: inotify-receiver
    network_mode: "bridge" # or share with your media stack's service network
    restart: unless-stopped
    environment:
      - ROOT_MOVIES=/data/movies
      - ROOT_TV=/data/tv
      - ROOT_MUSIC=/data/music
      - MARKER_NAME=refresh
      - TTL=46
    volumes:
      - /mnt/fuse/Media/Movies:/data/movies:rw
      - /mnt/fuse/Media/TV_Shows:/data/tv:rw
      - /mnt/fuse/Media/Music:/data/music:rw
      - ./inotify-recv.sh:/usr/local/bin/inotify-recv.sh:ro
    command:
      - /bin/sh
      - -lc
      - |
        set -eu
        apk add --no-cache socat >/dev/null
        echo "[receiver] listening UDP 0.0.0.0:9999"
        exec socat -u UDP4-RECVFROM:9999,bind=0.0.0.0,fork SYSTEM:/usr/local/bin/inotify-recv.sh
    security_opt: ["no-new-privileges:true"]
    tmpfs: ["/tmp", "/run"]
```

`inotify-recv.sh` (drop in the same folder):

```sh
#!/bin/sh
set -eu
ROOT_MOVIES="${ROOT_MOVIES:-/data/movies}"
ROOT_TV="${ROOT_TV:-/data/tv}"
ROOT_MUSIC="${ROOT_MUSIC:-/data/music}"
MARKER_NAME="${MARKER_NAME:-refresh}"
TTL="${TTL:-46}"
log(){ printf '%s\n' "$*"; }
payload="$(cat | tr -d '\r\n')"; log "[receiver] recv: ${payload:-<empty>}"
case "$payload" in /data/*) ;; *) log "[receiver] reject (outside /data): $payload"; exit 0;; esac
target="$payload"; [ -d "$target" ] || target="$(dirname -- "$target" 2>/dev/null || echo "$payload")"
case "$target" in */) target="${target%/}";; esac
lib="other"
case "$target" in "$ROOT_MOVIES"/*|"$ROOT_MOVIES") lib="movies";;
                   "$ROOT_TV"/*|"$ROOT_TV")       lib="tvshows";;
                   "$ROOT_MUSIC"/*|"$ROOT_MUSIC") lib="music";; esac
tickle(){ t="$1"; [ -n "$t" ] || return 0; [ -d "$t" ] && [ -w "$t" ] || { log "[receiver] not writable: $t"; return 0; }
  key="$(printf '%s' "$t" | md5sum | awk '{print $1}')"; lock="/tmp/refresh-$key.lock"
  if mkdir "$lock" 2>/dev/null; then marker="$t/$MARKER_NAME"
    if : >"$marker" 2>/dev/null; then log "[receiver] refresh touched: $marker (delete in ${TTL}s)"
      ( sleep "$TTL"; rm -f "$marker"; rmdir "$lock" 2>/dev/null || true; log "[receiver] refresh removed: $marker" ) &
    else log "[receiver] create failed: $marker"; rmdir "$lock" 2>/dev/null || true; fi
  else log "[receiver] refresh already pending for $t"; fi
}
case "$lib" in
  movies)   tickle "$target"; tickle "$ROOT_MOVIES" ;;
  tvshows)  tickle "$target"; tickle "$ROOT_TV"     ;;
  music)    tickle "$target"
            rp="${target#$ROOT_MUSIC}"; rp="${rp#/}"; artist="${rp%%/*}"
            [ -n "$artist" ] && [ "$ROOT_MUSIC/$artist" != "$target" ] && tickle "$ROOT_MUSIC/$artist" ;;
  *)        log "[receiver] ignore: $target" ;;
esac
```

**Expose port:** If your receiver is on a different host/network namespace, publish UDP/9999 (or share a service network with your media stack). Lock it down to LAN only (see *Security*).

---

### 2) Sender (runs on Unraid / the storage box)

Use an inotify container (e.g., `devodev/inotify`) or any watcher that can execute a script on change. The key is to send the **absolute** path (as seen by the receiver) to one or more hosts:

```yaml
# docker-compose.yml (sender side, Unraid/NAS)
services:
  inotify-sender:
    image: devodev/inotify:0.3.0
    container_name: inotify-sender
    restart: unless-stopped
    environment:
      WATCH_DIRS: "/watch/Movies,/watch/TV,/watch/Music"
      REMOTE_HOSTS: "192.168.1.33,192.168.1.40" # comma-separated receivers
      REMOTE_PORT: "9999"
      # Optional: filter out marker names so we don't loop on our own tickles
      IGNORE_NAMES: "refresh"
    volumes:
      - /mnt/user/Media/Movies:/watch/Movies:ro
      - /mnt/user/Media/TV_Shows:/watch/TV:ro
      - /mnt/user/Media/Music:/watch/Music:ro
      - ./sender.sh:/sender.sh:ro
    command: ["/bin/bash","/sender.sh"]
```

`sender.sh` (broadcast to multiple receivers; adapt to your watcher’s env):

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=',' read -r -a HOSTS <<< "${REMOTE_HOSTS:-127.0.0.1}"
PORT="${REMOTE_PORT:-9999}"

# devodev/inotify passes events to this script's stdin as absolute paths
# (If your watcher behaves differently, normalize to the receiver’s /data/... layout.)
while read -r path; do
  # Basic ignore (avoid loops on our own 'refresh' markers)
  base="$(basename -- "$path" || true)"
  if [[ "${IGNORE_NAMES:-}" =~ (^|,)${base}(,|$) ]]; then
    continue
  fi

  # Map sender paths to receiver paths if needed:
  # e.g., /watch/Movies/...  ->  /data/movies/...
  case "$path" in
    /watch/Movies/*) out="/data/movies/${path#/watch/Movies/}" ;;
    /watch/TV/*)     out="/data/tv/${path#/watch/TV/}"         ;;
    /watch/Music/*)  out="/data/music/${path#/watch/Music/}"   ;;
    *)               continue ;;
  esac

  for h in "${HOSTS[@]}"; do
    printf '%s' "$out" | socat -u - "UDP4:${h}:${PORT}" || true
  done
done
```

> **Note:** If your watcher can emit *directory* paths on creates/moves, prefer that (less noise). Otherwise, the receiver gracefully resolves files to their parent directory.

---

## Port, networking & security

* **Port:** UDP **9999** by default (configurable).
* **Firewall:** allow from **trusted LAN hosts only** (e.g., Unraid/NAS → media servers).
* **Docker publish:** if receivers are on different hosts, publish `9999/udp` and limit to your LAN interface where possible.
* **No auth:** payloads are just absolute paths; keep this traffic on private networks.

---

## Environment variables (receiver)

| Var           | Default        | Meaning                                |
| ------------- | -------------- | -------------------------------------- |
| `ROOT_MOVIES` | `/data/movies` | Movies library root                    |
| `ROOT_TV`     | `/data/tv`     | TV library root                        |
| `ROOT_MUSIC`  | `/data/music`  | Music library root                     |
| `MARKER_NAME` | `refresh`      | Marker filename created/deleted        |
| `TTL`         | `46`           | Seconds to keep marker before deleting |

---

## Operational notes & lessons learned

* **Double tickle helps Movies/TV**: touching both the specific folder and the library root greatly improves discovery of *new* titles.
* **Music is trickier**: new artists/albums are most reliable when also touching the **artist** top-level folder.
* **Large trees over NFS** can make Jellyfin’s crawler time out; the tickler approach reduces scan scope and tends to be more reliable.
* **Debounce**: per-directory locks in `/tmp` prevent storming during bursty creates/moves.
* **UMASK/permissions**: ensure the receiver has **write** access to library paths (so it can create the marker file). Containers often use `PUID/PGID`—match your media stack.

---

## Testing

Manual single tick:

```bash
# From any host that can reach the receiver
printf '/data/movies' | socat -u - UDP4:RECEIVER_IP:9999
```

Watch receiver logs:

```
[receiver] recv: /data/movies
[receiver] refresh touched: /data/movies/refresh (will delete in 46s)
[receiver] refresh removed: /data/movies/refresh
```

You should then see your media server pick up changes.

---

## Troubleshooting

* **Nothing happens:**

  * Confirm UDP reaches the receiver (use `tcpdump -ni any udp port 9999`).
  * Check container logs; ensure `inotify-recv.sh` is executable and `socat` installed.
  * Verify receiver has **write** permissions on mounted paths.
* **Loops/storms:**

  * Ensure the **sender ignores `refresh`** markers (see `IGNORE_NAMES`).
  * Keep `TTL` > a few seconds to give the media server time to react.
* **Inotify limits (sender):**

  * For gigantic trees, you may need to raise `fs.inotify.max_user_watches` on the **host** (not inside the container). On Unraid, set it via `/boot/config/go` or `sysctl` plugin.

---

## Compatibility

* **Jellyfin**: Works well with the tickle pattern above. For truly massive “New” folders, consider temporarily ingesting into smaller artist folders to avoid full-tree crawls.
* **Plex**: Also responds to marker touches; Movies/TV discovery is generally more forgiving.

---

## Example: integrating with a Jellyfin stack

Your media server container can share a network namespace with the receiver (or just be on the same bridge). Example (abridged):

```yaml
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    volumes:
      - /mnt/fuse/Media/Movies:/data/movies:ro
      - /mnt/fuse/Media/TV_Shows:/data/tv:ro
      - /mnt/fuse/Media/Music:/data/music:ro
    # …

  inotify-receiver:
    # (use the receiver service from above)
    # share the same volumes, but RW, so it can create 'refresh'
```

---

## Design choices (TL;DR of the journey)

* Tried pure API refreshes → **insufficient** for brand-new items, especially Music.
* Learned inotify **doesn’t propagate** over NFS reliably → switched to a **marker-file** trigger.
* Found **double tickle** (target + root) helps Movies/TV; **artist tickle** helps Music.
* Added **debounce locks** and **TTL cleanup** to keep things quiet and reliable.
* Works across **multiple receivers** (broadcast), minimal dependencies, low complexity.

---

## Roadmap

* Optional **allowlist/denylist** per library.
* Pluggable **path mapping** (sender side) for more complex topologies.
* Optional **metrics** (Prometheus textfile or logs).

---

## License

MIT 

---

## Credits

Originally built and field-tested by **@abl030** on Unraid + NixOS stacks with Jellyfin/Plex over FUSE-mounted NFS libraries. Contributions welcome!

