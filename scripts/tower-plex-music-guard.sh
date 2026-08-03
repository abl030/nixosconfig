#!/bin/bash
# Ensure Plex's boot-time bind of the prom music library is backed by NFS.
# Unraid starts Docker before Unassigned Devices mounts remote shares. Docker's
# rprivate bind keeps the pre-mount tmpfs view until the container is recreated.
set -u

container="${PLEX_CONTAINER:-binhex-plexpass}"
host_mount="${PLEX_MUSIC_HOST_MOUNT:-/mnt/remotes/192.168.1.12_Music}"
container_mount="${PLEX_MUSIC_CONTAINER_MOUNT:-/prom_music}"
mounts_file="${PLEX_MUSIC_MOUNTS_FILE:-/proc/mounts}"
lock_file="${PLEX_MUSIC_GUARD_LOCK:-/var/run/plex-music-guard.lock}"
interval="${PLEX_MUSIC_GUARD_INTERVAL:-5}"

log() {
  logger -t plex-music-guard -- "$*"
}

host_mount_is_nfs() {
  while IFS=' ' read -r _source target fstype _rest; do
    if [[ "$target" == "$host_mount" && ("$fstype" == "nfs" || "$fstype" == "nfs4") ]]; then
      return 0
    fi
  done <"$mounts_file"
  return 1
}

exec 9>"$lock_file"
if ! flock -n 9; then
  exit 0
fi

log "waiting for NFS mount $host_mount and running container $container"
while true; do
  if ! command -v docker >/dev/null 2>&1 || ! host_mount_is_nfs; then
    sleep "$interval"
    continue
  fi

  if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]]; then
    sleep "$interval"
    continue
  fi

  container_fstype="$(timeout 10 docker exec "$container" stat -f -c %T "$container_mount" 2>/dev/null || true)"
  if [[ "$container_fstype" == "nfs" ]]; then
    log "$container already sees NFS at $container_mount"
    exit 0
  fi

  log "$container sees ${container_fstype:-unknown} at $container_mount after NFS became ready; restarting container"
  if ! docker restart "$container" >/dev/null; then
    log "failed to restart $container"
    exit 1
  fi

  container_fstype="$(timeout 10 docker exec "$container" stat -f -c %T "$container_mount" 2>/dev/null || true)"
  if [[ "$container_fstype" != "nfs" ]]; then
    log "$container still sees ${container_fstype:-unknown} at $container_mount after restart"
    exit 1
  fi

  log "$container now sees NFS at $container_mount"
  exit 0
done
