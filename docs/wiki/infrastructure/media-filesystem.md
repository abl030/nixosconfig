# Media filesystem layout (mergerfs + virtiofs + tower NFS)

**Last updated:** 2026-04-15
**Status:** working
**Hosts:** `igpu` (consumer), `proxmox-vm`/doc1 (consumer), `prom` (storage), `tower`/Unraid (storage)
**Owner:** `modules/nixos/services/mounts/fuse.nix` + `hosts/igpu/configuration.nix` + `hosts.nix` (`igpu.proxmox.virtiofs`)
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208) (Phase 1)

## Why this is non-obvious

Jellyfin and friends consume **one** filesystem path per library (`/mnt/fuse/Media/Music`, etc.) but the bytes underneath that path come from **two** different storage backends with **different access modes**:

- **Media files** (the actual MKV / FLAC / etc.) — large, mostly read-only from jellyfin's perspective
- **Metadata** (NFOs, artwork, trickplay, subtitle caches) — small, hot, write-heavy during scans

Putting both on the same backend is wasteful (slow tower NFS for chatty metadata) or risky (filling fast prom NVMe with tens of TB of media). Mergerfs unions a fast write branch over a slow read branch and presents a single path.

The current split:

| Library  | Media (RO branch)                 | Metadata (RW branch)                       |
|----------|-----------------------------------|--------------------------------------------|
| Movies   | `/mnt/data/Media/Movies` (tower NFS) | `/mnt/virtio/media_metadata/Movies` (prom virtiofs) |
| TV Shows | `/mnt/data/Media/TV Shows` (tower NFS) | `/mnt/virtio/media_metadata/TV Shows` (prom virtiofs) |
| Music    | `/mnt/virtio/Music` (prom virtiofs) | `/mnt/virtio/media_metadata/Music` (prom virtiofs) |

Music is the odd one — both branches are on prom virtiofs because the canonical music tree itself moved to prom (it's the 668GB `nvmeprom/containers/Music` ZFS child dataset, served to soularr/lidarr/beets on doc2 via the same virtiofs). Movies and TV's media still lives on tower's spinning disks; only their metadata moved.

## Storage topology

```
                    prom (Proxmox host, AMD 9950X)
                    │
                    │ ZFS pool: nvmeprom/containers
                    │
                    ├── Music                  ← 668GB, jellyfin RO + lidarr RW
                    │   (ZFS child dataset)
                    │
                    └── media_metadata         ← 55GB, jellyfin/plex RW
                        ├── Movies             (Movies NFOs/trickplay rsync'd from tower)
                        ├── TV Shows           (TV Shows NFOs/trickplay rsync'd from tower)
                        └── Music              (intentionally empty — regenerated)
                    │
                    │ Both exposed as Proxmox virtiofs directory mappings:
                    │   `music`           → /nvmeprom/containers/Music
                    │   `media_metadata`  → /nvmeprom/containers/media_metadata
                    ▼
   ┌────────────────────────┬─────────────────────────┐
   │                        │                         │
  igpu (VM 109)           doc1/proxmox-vm (VM 104)   doc2 (VM 114)
   │                        │                         │
  virtiofs0=music          virtiofs0=containers      virtiofs0=containers
  virtiofs1=media_metadata (full mapping; child       virtiofs1=mirrors
   │                       datasets auto-submount)    │
   ▼                                                  ▼
  /mnt/virtio/Music        /mnt/virtio/Music         /mnt/virtio/Music
  /mnt/virtio/media_metadata                         /mnt/virtio/media_metadata
   │                       /mnt/virtio/media_metadata (auto-submount of child datasets)
   │
   │ + tower NFS at /mnt/data/Media (Movies / TV Shows media)
   │
   ▼
  mergerfs unions (fuse-mergerfs-{movies,tv,music,music-rw}.service)
   │
   ▼
  /mnt/fuse/Media/{Movies, TV_Shows, Music, Music_RW}  ← jellyfin/tdarr consume here
                                                          (production Plex lives on tower
                                                           and reads its own filesystem;
                                                           it's not a consumer of these unions)
```

## Why two scoped mappings on igpu, not the full `containers` mapping

doc1 and doc2 both have the full `containers` virtiofs mapping because they *are* the service hosts — they need to see every service's state directory (immich, paperless, mealie, soularr, etc.). igpu is a media transcoding box; exposing it to every other service's state would be unnecessary blast radius for a host whose only job is jellyfin/tdarr/plex.

So igpu gets two narrow mappings instead:

- `music` → only the Music ZFS child dataset
- `media_metadata` → only the media_metadata ZFS dataset

Both are added to `/etc/pve/mapping/directory.cfg` on prom (out-of-band — Proxmox doesn't render `directory.cfg` from a manifest) and attached to the VM via:

```
qm set 109 -virtiofs0 dirid=music -virtiofs1 dirid=media_metadata
qm shutdown 109   # NEVER `qm stop` — hard stop breaks iGPU PCIe FLR; see igpu-passthrough.md
qm start 109
```

The repo records the intent under `igpu.proxmox.virtiofs` in `hosts.nix`, but `ignoreInit = true` on the imported VM means OpenTofu won't reconcile it — `qm set` is the source of truth.

## Why the metadata moved off tower

Pre-#208 Phase 1, Movies/TV Shows/Music metadata all lived on tower at `/mnt/data/Media/Metadata/{Movies,TV Shows,Music}`. Jellyfin scans are extremely chatty against this directory:

- One trickplay PNG-grid file per video at multiple resolutions (hundreds of small writes per movie scan)
- NFOs regenerated on schema changes
- Artwork downloads
- Subtitle cache writes

Tower is Unraid on spinning disks. Each scan caused minutes of disk thrash that also blocked unrelated reads (Plex, Sonarr/Radarr). Moving metadata to prom NVMe drops scan times dramatically and decouples chatty writes from the media filesystem entirely.

The Music metadata wipe was deliberate — that tree was years-stale (different naming convention, half the albums had moved between releases) and we'd rather have jellyfin regenerate than carry forward bad NFOs. Movies and TV were rsync'd intact (8GB and 48GB respectively).

## What lives where (post-Phase 1)

Inside igpu, after a clean boot:

```
$ mount | grep -E 'virtiofs|fuse'
music on /mnt/virtio/Music type virtiofs (rw,relatime)
media_metadata on /mnt/virtio/media_metadata type virtiofs (rw,relatime)
mergerfs /mnt/data/Media/Movies (RO) + /mnt/virtio/media_metadata/Movies (RW) → /mnt/fuse/Media/Movies
mergerfs /mnt/data/Media/TV Shows (RO) + /mnt/virtio/media_metadata/TV Shows (RW) → /mnt/fuse/Media/TV_Shows
mergerfs /mnt/virtio/media_metadata/Music (RW) + /mnt/virtio/Music (RO) → /mnt/fuse/Media/Music
mergerfs /mnt/virtio/Music (RW) → /mnt/fuse/Media/Music_RW
```

The `Music_RW` wrapper exists so Lidarr (running on doc2) can write new albums into the canonical tree without having to know about the union. Jellyfin reads from `Music`; Lidarr writes to `Music_RW`; both ultimately hit the same `nvmeprom/containers/Music` dataset.

## Why the music NFS-server module was retired

`modules/nixos/services/mounts/nfs-music-server.nix` (deleted 2026-04-15) was a doc2-side NFS server intended to re-export `/mnt/virtio/Music` to other hosts (epi, framework, wsl). It was never enabled because **virtiofs lacks `FUSE_EXPORT_SUPPORT`** — the kernel NFS server can't generate stable file handles for virtiofs paths, so subdirectory mounts give stale-handle errors as soon as anything in the tree changes.

The replacement is direct prom-side NFS:

- `prom` exports `/nvmeprom/containers/Music` directly (kernel NFS over ZFS)
- Read-only export to `tower` (192.168.1.2)
- Read-write to `epi` (192.168.1.5), `framework` TS, `wsl` TS
- Client mount: `modules/nixos/services/mounts/nfs-music.nix` (`homelab.mounts.nfsMusic`) — defaults to `192.168.1.12:/`

Bypassing virtiofs sidesteps the FUSE_EXPORT_SUPPORT issue entirely. Direct NFS over ZFS gives stable handles.

## Operational gotchas

### `qm shutdown`, never `qm stop`

`qm stop` is a hard stop (qemu kill). On a VM with PCIe passthrough, hard-stops can leave the device in a state the next guest can't initialize — symptom is "amdgpu binds, no DRI device" requiring a Proxmox host reboot to clear. `qm shutdown 109` goes through qemu-guest-agent for a graceful OS halt and keeps the iGPU clean. See [igpu-passthrough.md](igpu-passthrough.md#failure-mode-driver-bound-no-dri-device).

If `qm shutdown` itself hangs (we hit this once during Phase 1), the only recovery is a Proxmox host reboot — same story.

### Metadata is on prom, not tower — backup planning

`nvmeprom/containers/media_metadata` is on prom NVMe and *not* part of tower's parity array. If it matters, it needs its own ZFS snapshot/replication policy. Today: regeneratable from a full library scan, so accepting the loss is reasonable. If we add hand-curated artwork or per-file overrides later, revisit.

### Mergerfs ordering on boot

Mergerfs units use `unitConfig.RequiresMountsFor` to wait for their underlying mounts:

- Movies/TV: requires `/mnt/virtio/media_metadata` (and `mnt-data.mount` for tower NFS)
- Music: requires `/mnt/virtio/Music` and `/mnt/virtio/media_metadata` only — **no** tower NFS dependency
- Music_RW: requires `/mnt/virtio/Music` only

Music units dropped their `mnt-data.mount` dependency in Phase 1. If tower goes down, Movies/TV unions go away (correct — the media is gone), but Music unions stay up because nothing they depend on is on tower anymore.

### doc1 also runs the mergerfs units

doc1 (proxmox-vm) enables `homelab.mounts.fuse.enable = true` for tautulli and the music compose stack. It picks up the same fuse.nix changes as igpu. This works because doc1 has the full `containers` mapping and `media_metadata` is a ZFS child dataset, so it auto-submounts at `/mnt/virtio/media_metadata` without any extra Proxmox config. Verified post-Phase 1 deploy: all four mergerfs units active on doc1 with the new branch paths.

### Adding a new library

If we add a fourth library (audiobooks, podcasts, whatever):

1. Decide storage: tower (large, cheap) or prom (small, fast)
2. Create a new ZFS child dataset on prom for its metadata (`zfs create nvmeprom/containers/media_metadata/<lib>` is sufficient; same `media_metadata` mapping serves it via subdirectory)
3. Add a new branch + dst path in `modules/nixos/services/mounts/fuse.nix`
4. Add a `RequiresMountsFor` line for whichever mounts the new branches read

No new virtiofs mapping needed unless the library lives outside both `Music` and `media_metadata`.

## Decision history

- **Pre-Phase 1**: All metadata on tower NFS; Music media on tower NFS; doc2 had a virtual NFS-music-server module that was never enabled (`FUSE_EXPORT_SUPPORT` blocker).
- **Phase 1 (this work)**: prom became the canonical host for Music + all metadata. Music traffic for doc2/igpu/desktops short-circuits tower entirely; Movies/TV media stays on tower for storage capacity reasons.
- **Considered and rejected**: Giving igpu the full `containers` virtiofs mapping (matches doc2) — works but exposes far more than igpu needs. Two narrow mappings keeps the blast radius scoped to "things jellyfin actually reads."
- **Considered and rejected**: Per-library metadata datasets (`music_metadata`, `movies_metadata`, `tv_metadata`) — three Proxmox mappings + three virtiofs devices + three fileSystems entries vs one. Per-library snapshot granularity is theoretical; one dataset snapshotted nightly covers all libraries. If we ever need per-library isolation, `zfs rename` + new mappings is a non-destructive upgrade.

## When to revisit

- When jellyfin migrates off compose to native `services.jellyfin` (Phase 3) — verify the union paths still map correctly inside the new module's library configs (paths in jellyfin's web UI need updating from `/data/movies` → `/mnt/fuse/Media/Movies` etc.).
- If tower retires or Movies/TV move to prom — collapse Movies/TV branches to pure virtiofs like Music.
- If the metadata dataset grows past ~200GB — check whether trickplay regeneration is doing something pathological, or whether per-library splits become worthwhile.

## Related

- `modules/nixos/services/mounts/fuse.nix` — the mergerfs unit definitions
- `modules/nixos/services/mounts/nfs-music.nix` — `homelab.mounts.nfsMusic` client mount (used by epi/framework/wsl, NOT igpu)
- `hosts.nix` (`igpu.proxmox.virtiofs`) — declared mappings (documentation only on imported VMs)
- `hosts/igpu/configuration.nix` — `fileSystems."/mnt/virtio/{Music,media_metadata}"` entries
- `hosts/doc2/configuration.nix` — full `containers` virtiofs mapping
- [`igpu-passthrough.md`](igpu-passthrough.md) — the `qm shutdown` vs `qm stop` rationale
