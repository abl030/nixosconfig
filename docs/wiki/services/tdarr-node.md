# tdarr-node on igpu

**Last updated:** 2026-04-15
**Status:** working
**Owner:** `modules/nixos/services/tdarr-node.nix`
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208)

## It's a *node*, not the server

Tdarr has a classic server/worker split. The **server** (web UI, job queue, library scan) runs on **tower (Unraid, 192.168.1.2)** and lives outside the NixOS fleet. This module only deploys a **worker node** on igpu, because that's where the AMD iGPU is and transcoding wants hardware encode.

```
  tower (Unraid)              igpu (NixOS)
  ┌────────────────┐          ┌──────────────────────┐
  │ tdarr-server   │◀─8266────│ tdarr-node (this)    │
  │ web UI :8265   │          │ /dev/dri passthrough │
  │ library / jobs │          │ ffmpeg 7 + VAAPI     │
  └────────────────┘          └──────────────────────┘
```

Consequences for module design:

- **No `homelab.localProxy.hosts` entry.** The node image exposes ports 8265–8267 in its manifest but nothing listens for external clients — management all happens on tower's web UI. The original `#208` issue text asked for a proxy; it was a misread of the role.
- **No `homelab.monitoring.monitors` entry.** There's no HTTP health endpoint to hit. Liveness is observed by tower (the server will show the node as "disconnected" if it drops); local visibility is via `journalctl -u podman-tdarr-node` and Loki (host=igpu).
- **No sops secret.** Previous compose had a `tdarr-igp.env` with `DUMMY=1` — all environment is static (serverIP, serverPort, nodeName). Deleted.

If you want an external view of whether the node is *connected* rather than just *running*, the right place to add it is a check against tower's tdarr server API, not a check against igpu.

## Where it lives

- **Host:** igpu
- **Data:** `/mnt/docker/tdarr/{configs,logs}` — still on local ext4 (not on virtiofs). Will move to `/mnt/virtio/tdarr` when igpu's container-storage retirement lands alongside the jellyfin migration (Phase 3 of #208).
- **Media mount:** `/mnt/data/Media` (NFS from tower) → bind-mounted to `/mnt/media` inside the container. Tower remains the source of truth for Movies/TV media; tdarr operates on those, not on Music. Music itself moved off tower to prom virtiofs in Phase 1 of #208 (see [`docs/wiki/infrastructure/media-filesystem.md`](../infrastructure/media-filesystem.md)) but tdarr only ever transcoded video.
- **Transcode scratch:** `/mnt/data/Media/Transcode Temp` → `/temp` inside the container (note: path contains a space; oci-containers handles it fine via `-v src:dst` since `-v` only splits on `:`)
- **Container runtime:** rootful podman via `virtualisation.oci-containers`, systemd unit `podman-tdarr-node.service`
- **NFS watchdog:** `homelab.nfsWatchdog.podman-tdarr-node.path = /mnt/data/Media` — restarts the service if the mount goes stale

## `/dev/dri` passthrough

```nix
virtualisation.oci-containers.containers.tdarr-node = {
  # ...
  extraOptions = ["--device=/dev/dri:/dev/dri"];
};
```

That's it — container runs as root inside (PUID=0/PGID=0), so it has read/write on `card1` and `renderD128` without needing `video`/`render` group mapping. Verified at boot by tdarr's own encoder-probe output:

```
encoder-enabled-working, libx264-true-true, libx265-true-true,
  hevc_vaapi-true-true, libsvtav1-true-true, ...
```

`hevc_vaapi-true-true` is the "iGPU is working" signal. If this flips to `-false`, check `docs/wiki/infrastructure/igpu-passthrough.md` for the "driver bound, no DRI device" failure mode (answer: reboot Proxmox host).

## Non-obvious things we learned

### Shared `storage.conf` race between rootful and rootless podman

**Resolved as of Phase 3 of #208** — igpu's rootless compose infrastructure is retired (jellyfin went native; plex2 was removed in `739dd48`). tdarr-node is the only podman consumer on igpu and runs rootful. The race described below is now impossible on igpu. Kept for context in case anything similar comes up elsewhere.

Historically: igpu ran the jellyfin rootless compose stack under `abl030` *and* rootful podman via `oci-containers` for tdarr-node. The `homelab.containers` module (`modules/nixos/homelab/containers/default.nix:334`) installs a **global** `/etc/containers/storage.conf` forcing:

```
[storage]
graphroot = "/mnt/docker/containers"
runroot   = "/run/user/1000/containers"
```

…which is fine for the rootless backend (that's abl030's actual runtime dir) but means the **rootful** backend also uses `/run/user/1000/containers` when it runs. If anything root-owned ever writes into that path (a system-level script running with `XDG_RUNTIME_DIR=/run/user/1000`, a systemd service, etc.), the rootless backend subsequently refuses to start:

```
Error: configure storage: mkdir /run/user/1000/containers/overlay: permission denied
```

This bit us on doc1 during the `#208` cleanup — a stale root-owned `/run/user/1000/containers` from Apr 7 deadlocked the user podman socket. Fix:

```
sudo rm -rf /run/user/1000/containers
sudo chown -R abl030:users /run/user/1000
systemctl --user reset-failed podman.socket podman.service
systemctl --user start podman.socket
```

**When to revisit:** if this bites a third time, split `storage.conf` per-backend (rootful at `/var/lib/containers`, rootless at `/mnt/docker/containers`), or move tdarr-node's rootful storage explicitly via the container's `extraOptions`.

### Data dir ownership flipped on migration

Pre-migration (compose, rootless): `/mnt/docker/tdarr/{configs,logs}` was `abl030:users 0750`. New module declares `root:root 0755` via `systemd.tmpfiles.rules`. We stopped the old rootless container **before** deploying so tmpfiles didn't chown under a running process. Existing files (abl030:users) are still readable by the new root-inside-container because mode was 0750 with world-none but root bypasses DAC via `CAP_DAC_READ_SEARCH`. New files land as root:root. Clean.

If this gets re-run on a fresh host, tmpfiles will just create the dirs root-owned from scratch.

### Node connects outbound only; no firewall port needed

Old compose had `firewallPorts = [8265]` which was a copy-paste from the tdarr *server* port. The node never binds any public port — it dials tower on 8266. Dropped in the new module. Nothing to open on igpu's firewall.

### `ffmpegVersion=7` matters

Tdarr images ship both ffmpeg 6 and 7. With ffmpeg 6 we were seeing occasional VAAPI session timeouts on the 9950X iGPU; ffmpeg 7 resolved it. The env var is set in the module.

## How to update

Image is `ghcr.io/haveagitgat/tdarr_node:latest`. The `homelab.podman` registry (`modules/nixos/homelab/podman.nix`) pulls newer images nightly and restarts `podman-tdarr-node.service` only if the digest changed. To force an update:

```
ssh igp 'sudo systemctl start podman-update-containers.service'
```

Node version must match server version. If the server on tower is upgraded, the node will refuse to connect until pulled; the nightly timer covers that after one cycle, or run the command above.

## When to revisit

- When igpu's tdarr config moves to virtiofs → switch `dataDir` default in the module from `/mnt/docker/tdarr` to `/mnt/virtio/tdarr`, migrate existing configs/logs, update host config. igpu now has the broad `containers` virtiofs mapping (Phase 3 of #208), so `/mnt/virtio/tdarr` just needs `mkdir /nvmeprom/containers/tdarr` on prom — no per-service mapping needed.
- `homelab.containers.enable` is now `false` on igpu as of Phase 3 of #208 (jellyfin + plex2 retired, compose infrastructure gone). tdarr-node is rootful OCI via `homelab.podman`, so no `storage.conf` shared-race anymore.
- If tdarr's server moves off tower → `serverIp` / `serverPort` are configurable; just update the host-level enable block.
- If we want external monitoring → wire a Kuma check against tower's tdarr server API, not against igpu.

## Related

- `modules/nixos/services/tdarr-node.nix` — the module
- `modules/nixos/services/nfs-watchdog.nix` — watchdog plumbing
- `modules/nixos/homelab/podman.nix` — rootful OCI infrastructure
- `modules/nixos/homelab/containers/default.nix` — rootless compose infrastructure (no longer used on igpu)
- `docs/wiki/infrastructure/igpu-passthrough.md` — `/dev/dri` passthrough health + failure mode
- `docs/wiki/infrastructure/media-filesystem.md` — Music/Metadata virtiofs layout (Phase 1 of #208)
