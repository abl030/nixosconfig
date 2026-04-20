# Media filesystem layout (mergerfs + virtiofs + tower NFS)

**Last updated:** 2026-04-15
**Status:** working
**Hosts:** `igpu` (consumer), `proxmox-vm`/doc1 (consumer), `prom` (storage), `tower`/Unraid (storage)
**Owner:** `modules/nixos/services/mounts/fuse.nix` + `hosts/igpu/configuration.nix` + `hosts.nix` (`igpu.proxmox.virtiofs`)
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208) (Phases 1 + 3)

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

Music is the odd one — both branches are on prom virtiofs because the canonical music tree itself moved to prom (it's the 668GB `nvmeprom/containers/Music` ZFS child dataset, served to cratedigger/lidarr/beets on doc2 via the same virtiofs). Movies and TV's media still lives on tower's spinning disks; only their metadata moved.

## Storage topology

```
                    prom (Proxmox host, AMD 9950X)
                    │
                    │ ZFS pool: nvmeprom/containers   ← one broad virtiofs mapping (`containers`)
                    │                                    shared by doc1, doc2, igpu
                    ├── Music                ← 668GB ZFS child dataset (jellyfin RO + lidarr RW)
                    │                          Auto-submounts at /mnt/virtio/Music in every guest.
                    │
                    ├── media_metadata       ← 55GB ZFS child dataset (jellyfin RW)
                    │   ├── Movies             (Movies NFOs/trickplay rsync'd from tower)
                    │   ├── TV Shows           (TV Shows NFOs/trickplay rsync'd from tower)
                    │   └── Music              (intentionally empty — regenerated)
                    │                          Auto-submounts at /mnt/virtio/media_metadata.
                    │
                    ├── jellyfin             ← plain dir, jellyfin --datadir + configdir + ts-share
                    │                          (Phase 3 of #208; owned root:root 0755 so
                    │                          jellyfin-owned and root-owned children coexist.)
                    │
                    ├── <all other service state>   atuin, immich, paperless, mealie, cratedigger, ...
                    ▼
   ┌────────────────────────┬─────────────────────────┐
   │                        │                         │
  igpu (VM 109)           doc1/proxmox-vm (VM 104)   doc2 (VM 114)
   │                        │                         │
  virtiofs0=containers     virtiofs0=containers      virtiofs0=containers
                                                     virtiofs1=mirrors
   │                        │                         │
   ▼ Guest sees /mnt/virtio/ with Music, media_metadata, jellyfin, immich, ... all visible.
   │ (ZFS child datasets propagate automatically as virtiofs submounts.)
   │
   │ igpu additionally mounts tower NFS at /mnt/data/Media (Movies / TV Shows media).
   │ doc1 also mounts tower NFS for its own workloads.
   │
   ▼
  mergerfs unions (fuse-mergerfs-{movies,tv,music,music-rw}.service)
   │
   ▼
  /mnt/fuse/Media/{Movies, TV_Shows, Music, Music_RW}  ← jellyfin (native) + tdarr consume here
                                                          (production Plex lives on tower
                                                           and reads its own filesystem;
                                                           it's not a consumer of these unions)
```

## Why one broad `containers` mapping on every host

doc1 and doc2 always had the full `containers` mapping because they're the service hosts — they need to see every service's state dir (immich, paperless, mealie, cratedigger, …). As of Phase 3 of #208, igpu follows the same pattern: jellyfin runs native (`dataRoot = /mnt/virtio/jellyfin`) alongside tdarr-node, so it needs the same broad view.

Phase 1 originally tried a narrow approach for igpu — separate `music` + `media_metadata` directory mappings — to minimise blast radius. That worked for the Phase 1 scope (virtiofs music only) but fell apart in Phase 3 when we added jellyfin state, which would have required yet another narrow mapping. A single broad mapping is the cleaner pattern and matches the rest of the fleet. See the [decision history](#decision-history) below.

One mapping declared on prom:

```
# /etc/pve/mapping/directory.cfg (on prom)
containers
    map node=prom,path=/nvmeprom/containers
    description Podman containers dataset
```

Attached to each guest VM via `qm set <vmid> -virtiofs0 dirid=containers` (plus any host-specific extras like `mirrors`). For imported VMs (`ignoreInit = true` in `hosts.nix`) `qm set` is the source of truth; the `virtiofs = [...]` entry in `hosts.nix` is documentation only.

## Why the metadata moved off tower

Pre-#208 Phase 1, Movies/TV Shows/Music metadata all lived on tower at `/mnt/data/Media/Metadata/{Movies,TV Shows,Music}`. Jellyfin scans are extremely chatty against this directory:

- One trickplay PNG-grid file per video at multiple resolutions (hundreds of small writes per movie scan)
- NFOs regenerated on schema changes
- Artwork downloads
- Subtitle cache writes

Tower is Unraid on spinning disks. Each scan caused minutes of disk thrash that also blocked unrelated reads (Plex, Sonarr/Radarr). Moving metadata to prom NVMe drops scan times dramatically and decouples chatty writes from the media filesystem entirely.

The Music metadata wipe was deliberate — that tree was years-stale (different naming convention, half the albums had moved between releases) and we'd rather have jellyfin regenerate than carry forward bad NFOs. Movies and TV were rsync'd intact (8GB and 48GB respectively).

## What lives where (current)

Inside igpu, after a clean boot:

```
$ mount | grep -E 'virtiofs|fuse'
containers on /mnt/virtio type virtiofs (rw,relatime)
none on /mnt/virtio/Music type virtiofs (rw,relatime)           ← ZFS child-dataset auto-submount
none on /mnt/virtio/media_metadata type virtiofs (rw,relatime)  ← same
mergerfs /mnt/data/Media/Movies (RO) + /mnt/virtio/media_metadata/Movies (RW) → /mnt/fuse/Media/Movies
mergerfs /mnt/data/Media/TV Shows (RO) + /mnt/virtio/media_metadata/TV Shows (RW) → /mnt/fuse/Media/TV_Shows
mergerfs /mnt/virtio/media_metadata/Music (RW) + /mnt/virtio/Music (RO) → /mnt/fuse/Media/Music
mergerfs /mnt/virtio/Music (RW) → /mnt/fuse/Media/Music_RW
```

The `Music_RW` wrapper exists so Lidarr (running on doc2) can write new albums into the canonical tree without having to know about the union. Jellyfin reads from `Music`; Lidarr writes to `Music_RW`; both ultimately hit the same `nvmeprom/containers/Music` dataset.

Jellyfin itself stores its state under `/mnt/virtio/jellyfin` (Phase 3 of #208):

```
/mnt/virtio/jellyfin/       root:root 0755  (parent, so siblings below coexist)
├── data/                   jellyfin:jellyfin 0750  — --datadir (libraries.db, plugins, metadata cache)
├── config/                 jellyfin:jellyfin 0750  — --configdir (XML files)
├── log/                    jellyfin:jellyfin 0750  — --logdir
└── ts/                     root:root 0755          — homelab.tailscaleShare.jellyfin state
```

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

`qm stop` is a hard stop (qemu kill). On a VM with PCIe passthrough, hard-stops leave the device in a state the next guest can't initialize — symptom is "amdgpu binds, no DRI device" requiring a Proxmox host reboot to clear. `qm shutdown 109` goes through qemu-guest-agent for a graceful OS halt and keeps the iGPU clean. See [igpu-passthrough.md](igpu-passthrough.md#failure-mode-driver-bound-no-dri-device).

`qm shutdown` has fallen through to a hard stop multiple times during #208 work — tracked in [#211](https://github.com/abl030/nixosconfig/issues/211). Recovery is always a Proxmox host reboot.

### tmpfiles ordering: parent before child

When one module creates `/path/to/foo` (root-owned) and another creates `/path/to/foo/bar` (root-owned) via `systemd.tmpfiles.rules`, both merge into a single `/etc/tmpfiles.d/00-nixos.conf` in the order the modules are imported. If the child rule lands first, tmpfiles silently fails because the parent doesn't exist yet.

Fix: wrap the parent rule in `lib.mkBefore` so it's pinned ahead:

```nix
systemd.tmpfiles.rules = lib.mkBefore [
  "d ${cfg.dataRoot} 0755 root root - -"
];
```

This bit us on the jellyfin module before `lib.mkBefore` was added — tailscaleShare's child rules for `${dataRoot}/ts` fired before our parent rule.

### systemd-tmpfiles "unsafe path transition"

If a tmpfiles rule would create a root-owned dir inside a non-root-owned parent, systemd-tmpfiles refuses with:

```
Detected unsafe path transition /foo (owned by X) → /foo/bar (owned by root)
```

Keep the parent root-owned. In the jellyfin module this is why `dataRoot` is root:root 0755; inside it, `data/`, `config/`, `log/` are jellyfin-owned and `ts/` is root-owned — all siblings of a root-owned parent, no transitions through a non-root node.

Also affects pre-existing directories created on prom: if `/nvmeprom/containers/<service>` is owned by uid 1000 (the user running `mkdir`), virtiofs presents it as `abl030:users` on the guest and tmpfiles can't create root-owned children inside. Fix: `chown root:root /nvmeprom/containers/<service>` on prom before first deploy.

### Metadata is on prom, not tower — backup planning

`nvmeprom/containers/media_metadata` is on prom NVMe and *not* part of tower's parity array. If it matters, it needs its own ZFS snapshot/replication policy. Today: regeneratable from a full library scan, so accepting the loss is reasonable. If we add hand-curated artwork or per-file overrides later, revisit.

### Mergerfs ordering on boot

Mergerfs units use `unitConfig.RequiresMountsFor` to wait for their underlying mounts:

- Movies/TV: requires `/mnt/virtio/media_metadata` (and `mnt-data.mount` for tower NFS)
- Music: requires `/mnt/virtio/Music` and `/mnt/virtio/media_metadata` only — **no** tower NFS dependency
- Music_RW: requires `/mnt/virtio/Music` only

Music units dropped their `mnt-data.mount` dependency in Phase 1. If tower goes down, Movies/TV unions go away (correct — the media is gone), but Music unions stay up because nothing they depend on is on tower anymore.

### doc1 also runs the mergerfs units

doc1 (proxmox-vm) enables `homelab.mounts.fuse.enable = true` for tautulli and the music compose stack. It picks up the same fuse.nix changes as igpu. This works because doc1 has the full `containers` mapping and `media_metadata`/`Music` are ZFS child datasets, so they auto-submount without any extra Proxmox config. All four mergerfs units are active on doc1 with the same branch paths as igpu.

### Adding a new library

If we add a fourth library (audiobooks, podcasts, whatever):

1. Decide storage: tower (large, cheap) or prom (small, fast)
2. Create a new subdir on prom: `mkdir /nvmeprom/containers/media_metadata/<lib>` (or a sibling ZFS dataset if snapshot isolation matters)
3. Add a new branch + dst path in `modules/nixos/services/mounts/fuse.nix`
4. Add a `RequiresMountsFor` line for whichever mounts the new branches read

No new Proxmox mapping needed — the broad `containers` mapping already serves everything under `/nvmeprom/containers/`.

### Migrating an existing library database

If moving a service from LSIO/compose to native where its database stores absolute paths (like jellyfin's libraries.db with `/config/...` or `/data/...`), do SQL `UPDATE ... SET col = replace(col, old, new) WHERE col LIKE old || '%'` rather than symlinks. Symlinks are a transitional hack; the DB should reference the real target paths. See the Phase 3 migration in #208 for a worked example (322,811 rows updated across 4 tables).

## Decision history

- **Pre-Phase 1**: All metadata on tower NFS; Music media on tower NFS; doc2 had a virtual NFS-music-server module that was never enabled (`FUSE_EXPORT_SUPPORT` blocker).
- **Phase 1**: prom became the canonical host for Music + all metadata. Music traffic for doc2/igpu/desktops short-circuits tower entirely; Movies/TV media stays on tower for storage capacity reasons. **Initially** we used narrow per-purpose virtiofs mappings on igpu (`music`, `media_metadata`) for blast-radius isolation.
- **Phase 3**: Collapsed igpu to the broad `containers` mapping (like doc1/doc2). Jellyfin state lives at `/mnt/virtio/jellyfin` alongside everything else. The narrow-mapping approach didn't scale — adding each new service to igpu would have needed its own Proxmox mapping + `qm set` + VM restart. One broad mapping is the cleaner pattern and matches the rest of the fleet.
- **Considered and rejected**: Per-library metadata ZFS datasets (`music_metadata`, `movies_metadata`, `tv_metadata`) — three Proxmox mappings + three virtiofs devices + three fileSystems entries vs one. Per-library snapshot granularity is theoretical; one dataset snapshotted nightly covers all libraries. If we ever need per-library isolation, `zfs rename` + new mappings is a non-destructive upgrade.

## When to revisit

- If tower retires or Movies/TV move to prom — collapse Movies/TV branches to pure virtiofs like Music.
- If the metadata dataset grows past ~200GB — check whether trickplay regeneration is doing something pathological, or whether per-library splits become worthwhile.
- If `qm shutdown` is reliable again ([#211](https://github.com/abl030/nixosconfig/issues/211) closed) — maintenance windows for igpu get cheaper.

## Related

- `modules/nixos/services/mounts/fuse.nix` — the mergerfs unit definitions
- `modules/nixos/services/mounts/nfs-music.nix` — `homelab.mounts.nfsMusic` client mount (used by epi/framework/wsl, NOT igpu)
- `modules/nixos/services/jellyfin.nix` — native jellyfin; `dataRoot = /mnt/virtio/jellyfin`
- `hosts.nix` (`igpu.proxmox.virtiofs`) — declared mappings (documentation only on imported VMs)
- `hosts/igpu/configuration.nix` — `fileSystems."/mnt/virtio"` entry pointing at `containers`
- `hosts/doc2/configuration.nix` — same `containers` mapping
- [`igpu-passthrough.md`](igpu-passthrough.md) — the `qm shutdown` vs `qm stop` rationale
