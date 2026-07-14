# Jellyfin (native, on igpu)

**Last updated:** 2026-07-14 (Music scope migration and metadata recovery)
**Status:** working
**Host:** `igpu` (LXC 107)
**Owner:** `modules/nixos/services/jellyfin.nix` under `homelab.services.jellyfin`
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208) (Phase 3)

> **I/O pressure from library scans / keyframe extraction?** See [infrastructure/igpu-io-pressure-tuning](../infrastructure/igpu-io-pressure-tuning.md) — root cause (raidz1 latency + mergerfs cache), ranked reversible tuning levers, and what to leave alone.

## Deployment shape

Upstream nixpkgs `services.jellyfin` (10.11.8) wrapped by `homelab.services.jellyfin`. Replaces the compose stack retired in `#208` Phase 3.

**Runs alongside production Plex on tower, not as a replacement.** The two servers serve the same media library; jellyfin adds a second front-end with native VAAPI on the AMD iGPU. Tower-Plex remains the primary streaming target.

### Hardware transcoding

Declarative via upstream:

```nix
services.jellyfin.hardwareAcceleration = {
  enable = true;
  type = "vaapi";
  device = "/dev/dri/renderD128";
};
services.jellyfin.forceEncodingConfig = true;  # NixOS owns encoding.xml
services.jellyfin.transcoding.enableHardwareEncoding = true;
```

`forceEncodingConfig = true` means encoder settings in the web dashboard are overwritten on restart — the module's `transcoding.{hardwareEncodingCodecs,hardwareDecodingCodecs}` attrsets are authoritative.

RDNA3 iGPU supports HEVC + AV1 hardware encode; both enabled by default in the module.

### Filesystem layout

Single root-owned parent (`dataRoot`, default `/mnt/virtio/jellyfin`) so jellyfin-owned children (`data/`, `config/`, `log/`) and mixed-owner `tailscaleShare` children (`ts/`) can coexist without systemd-tmpfiles "unsafe path transition" errors:

```
/mnt/virtio/jellyfin/       root:root 0755  ← dataRoot (pre-created via tmpfiles.rules mkBefore)
├── data/                   jellyfin:jellyfin 0750  — --datadir: libraries.db, plugins, metadata
├── config/                 jellyfin:jellyfin 0750  — --configdir: system.xml / network.xml / ...
├── log/                    jellyfin:jellyfin 0750  — --logdir
└── ts/                     root:root 0755          — homelab.tailscaleShare.jellyfin state
    ├── ts-state/           root:root 0750          — tailscale node state
    ├── caddy-data/         tailscale-share-caddy 0750 — caddy cert/storage state
    └── caddy-config/       tailscale-share-caddy 0750 — caddy runtime config state
```

`/var/cache/jellyfin` stays on local igpu storage (regenerable; not worth virtiofs).

See [media-filesystem.md](../infrastructure/media-filesystem.md) for the mergerfs layout that backs `/mnt/fuse/Media/{Movies,TV_Shows,Music}`.

### Music library ownership and scope

Jellyfin library locations are **Jellyfin-owned persistent runtime state**, not
NixOS options. NixOS owns the service process and forced `encoding.xml`, but
must not generate pretend library configuration that Jellyfin does not read.
Manage locations through Jellyfin's library API/UI; the persistent shortcut is
under `data/root/default/<library>/`.

The `Music` virtual folder keeps item ID
`7e64e319657a9516ec78490da03edccb` and has exactly one location:

```text
/mnt/fuse/Media/Music/Beets
```

Do not point it at `/mnt/fuse/Media/Music`. That parent also contains
Cratedigger's `Incoming` staging/quarantine tree, `Re-download` evidence, and
other non-library working or legacy directories. In particular,
`Incoming/**/failed_imports` is protected evidence: exclude it structurally by
scoping Jellyfin to `Beets`; never delete or move it as library cleanup.

Cratedigger targets this stable library ID after imports. Its path map remains
`/mnt/virtio/Music/Beets:/mnt/fuse/Media/Music/Beets`.

#### 2026-07-13 Music scope migration

Changing the location in place preserved the virtual-folder ID and options, but
Jellyfin 10.11.11 left the removed parent tree searchable as phantom items after
a completed scan. This is upstream [jellyfin#14680](https://github.com/jellyfin/jellyfin/issues/14680),
not evidence that the configured location still includes the old path.

The completed migration used Jellyfin's structural library APIs rather than
per-item deletion: back up the database and `root/default/Music`, remove the
whole Music virtual folder, let Jellyfin purge the old collection, then recreate
Music with the backed-up options and only the Beets path. The `Music` item ID is
deterministic for this virtual-folder path, so recreation retained
`7e64e319657a9516ec78490da03edccb`.

The old collection contained two quarantine tracks with the same retained user
data key (the FLAC and partial Opus copies of `English Party`). Jellyfin's purge
therefore hit the 10.11 `UserData` uniqueness failure tracked in
[jellyfin#15343](https://github.com/jellyfin/jellyfin/issues/15343). Re-keying
one of those two retained user-data rows, without deleting a media item, allowed
Jellyfin's structural purge to finish. No file under `Incoming/failed_imports`
was moved, changed, or deleted. The pre-migration rollback snapshot is
`/mnt/virtio/jellyfin/backups/20260713T223500-music-scope/`.

Recreating the library exposed a second Jellyfin 10.11 behaviour: the normal
Cratedigger target (`POST /Items/<library-id>/Refresh`) defaults to
`metadataRefreshMode=None`. It rebuilt the Beets folder, album, and audio rows
but did not populate their media metadata. A completed `POST /Library/Refresh`
also left those existing rows unchanged. All 93,154 audio rows consequently had
`Album=NULL`, so Jellyfin's grouped `/Items/Latest` music query collapsed the
whole library into one bogus "Recently Added" group. The 8,437 album rows also
had folder-derived names and no artist, genre, year, or original creation date.

The recovery path-matched the rebuilt database against the pre-migration
snapshot with zero unmatched Beets audio or album rows. With Jellyfin stopped,
it restored only the erased media metadata on a verified copy, retained the new
structural parent/top-parent state and stable item IDs, passed SQLite
`quick_check`, and atomically installed the repaired database. The recovery
snapshots are:

- `/mnt/virtio/jellyfin/backups/20260714T083033-pre-audio-metadata-restore/`
- `/mnt/virtio/jellyfin/backups/20260714T084215-pre-album-metadata-restore/`

Never edit this WAL database underneath a running Jellyfin process. Stop
Jellyfin first, work on a copy, validate it, then replace the database before
starting the service. For future structural library recreation, do not treat a
default targeted refresh or default full-library scan as a metadata bootstrap;
preserve and restore the existing metadata or use an explicitly verified
metadata-refresh mode.

### Admin (abl030) debugging access

Upstream's defaults (mode 0700, UMask 0077) make every inspection require sudo. The module overrides:

- `users.users.${hostConfig.user}.extraGroups = ["jellyfin"]` — admin in jellyfin group
- `systemd.services.jellyfin.serviceConfig.UMask = "0027"` — new files land 0640
- `systemd.tmpfiles.settings.jellyfinDirs.*.d.mode = "0750"` — dirs group-traversable

Net effect: `ls /mnt/virtio/jellyfin/data/ROOT/` works without sudo. Writes still require sudo (mode 0640, not 0660) — that's rare enough to be fine.

### Two FQDNs

| Path | FQDN | Mechanism |
|---|---|---|
| LAN | `jelly.ablz.au` | `homelab.localProxy` → igpu nginx + ACME → `127.0.0.1:8096` |
| Inter-tailnet | `jellyfinn.ablz.au` | `homelab.tailscaleShare.jellyfin` → dedicated tailscale node + caddy → `host.docker.internal:8096` |

The compose stack used `jellyfinn.ablz.au` for external tailnet sharing; we kept the same FQDN to avoid reconfiguring downstream clients. `jelly.ablz.au` is the new short-form LAN convention (localProxy creates Cloudflare A records pointing at igpu's LAN IP; nginx terminates TLS with ACME).

`jellyfinn.ablz.au` uses the shared `tailscaleShare` hardening model: Caddy admin disabled, Caddy running as `tailscale-share-caddy` (`2011:2011`), only `NET_BIND_SERVICE` added back after dropping default capabilities, and Tailscale/Caddy state kept in separate mounts.

### Monitoring

Both FQDNs have Uptime Kuma monitors hitting `/System/Info/Public` (public, unauth endpoint).

NFS watchdog: `homelab.nfsWatchdog.jellyfin.path = /mnt/fuse/Media/TV_Shows`. Movies/TV_Shows media branches live on tower NFS; if stale, jellyfin library scans deadlock. Watchdog auto-restarts on staleness.

## Migration notes (#208 Phase 3 specifics)

### Path remapping in libraries.db

The LSIO compose image ran jellyfin with `--datadir /config/data` and `--configdir /config`, and mounted media at `/data/{tvshows,movies,music}` inside the container. After the rsync, those absolute paths are baked into libraries.db (322k references across `BaseItems.Path`, `BaseItemImageInfos.Path`, `MediaStreamInfos.Path`, `Chapters.ImagePath`).

Fix is a SQL `UPDATE ... SET col = replace(col, old, new)` pass:

| Old prefix | New prefix |
|---|---|
| `/data/tvshows` | `/mnt/fuse/Media/TV_Shows` |
| `/data/movies` | `/mnt/fuse/Media/Movies` |
| `/data/music` | `/mnt/fuse/Media/Music` |
| `/config/data` | `/mnt/virtio/jellyfin/data` |
| `/config/config` | `/mnt/virtio/jellyfin/config` |
| `/config/log` | `/mnt/virtio/jellyfin/log` |
| `/config/cache` | `/var/cache/jellyfin` |

Script in the #208 Phase 3 commit message. Worked cleanly in a single transaction with jellyfin stopped.

### Library options XML also had stale entries

`${dataDir}/root/default/<lib>/options.xml` stores library folder paths (matched to `.mblink` files in the same dir). We had to:

- Drop `<MediaPathInfo><Path>/data/</Path></MediaPathInfo>` from Movies/options.xml (orphan, no matching `.mblink`)
- Re-add a Music path (`<Path>/mnt/fuse/Media/Music</Path>`) and create `Music.mblink` containing `/mnt/fuse/Media/Music` — the Music library's `PathInfos` was empty after some earlier edit attempt. This records the 2026-05 migration state only; the live library was narrowed to `/mnt/fuse/Media/Music/Beets` on 2026-07-13 as documented above.

Jellyfin refuses to edit a library whose declared path doesn't resolve on disk. During migration we temporarily symlinked `/data` → real paths so the UI would let us edit; after the SQL fix + options.xml cleanup the symlinks were removed.

### The two compose-era DBs merged into one

LSIO jellyfin had both `jellyfin.db` and `library.db` in some older versions; 10.11.8 consolidates into a single `jellyfin.db`. No special migration needed — rsync copies the file, jellyfin runs its own schema migrations on first start.

## Companion services (Phase 4 of #208)

Jellystat (analytics) and watchstate (Plex<->Jellyfin sync) live in the same module as independently-toggled sub-services. Both run on **doc2** (not igpu — they don't need the iGPU).

### Jellystat

```nix
homelab.services.jellyfin.jellystat.enable = true;
```

OCI container `cyfershepard/jellystat:latest` + nspawn PostgreSQL (mk-pg-container, hostNum=7).

| | |
|---|---|
| FQDN | `jellystat.ablz.au` |
| Host port | 3010 (container 3000) |
| DB | nspawn `jellystat-db`, user=jellystat, database=jfstat (upstream default, via `extraDatabases`) |
| Data | `/mnt/virtio/jellystat/backup-data` (`jellystat:users`, UID 2014); `postgres/` is pg-internal (`0700 root`) |
| Kuma monitor | `https://jellystat.ablz.au/` |

Container runs as `--user=2014:100` — a **dedicated `jellystat` service UID (2014)**, never host UID 1000 (`abl030`). UID 1000 has passwordless sudo, so a popped container running as it would inherit root; jellystat honours `--user` directly so it gets a clean dedicated UID like youtarr(2009)/tdarr(2010). See forgejo#2 / #232 and the "No container ever runs as host UID 1000" rule in `nixos-service-modules.md`. Connects to nspawn PG at `10.20.0.15:5432` via podman MASQUERADE (source IP rewritten to host-side veth `10.20.0.14`, authenticated with **scram-sha-256** — `trust` over TCP was retired in #232).

First-run setup: visit `https://jellystat.ablz.au/`, add Jellyfin API key + URL (`https://jelly.ablz.au`), trigger initial sync.

### watchstate

```nix
homelab.services.jellyfin.watchstate.enable = true;
```

OCI container `ghcr.io/arabcoders/watchstate:latest`, no DB.

| | |
|---|---|
| FQDN | `watchstate.ablz.au` |
| Host port | 8099 (container 8080) |
| Data | `/mnt/virtio/watchstate` mounted as `/config:U` (owned by host UID **201000** after the userns remap) |
| Kuma monitor | `https://watchstate.ablz.au/` |

**UID handling — userns remap, NOT `--user`.** watchstate's image hardcodes a
UID-1000 `user`, which under rootful podman *is* host `abl030` (passwordless
sudo). Its `WS_UID` switch can't relocate that user under `cap-drop=all` — it
crash-loops. So the whole container is userns-remapped
(`--uidmap=0:200000:65536` / `--gidmap=0:200000:65536`): container UID 1000 →
host **201000**, never `abl030`. `WS_UID` stays `1000` (the image's happy
default; no in-container switch). The `:U` flag on the `/config` volume migrated
the existing abl030-owned data into the mapped range on first start. See
forgejo#2 Phase 1b and the "No container ever runs as host UID 1000" rule in
`nixos-service-modules.md`.

Backends configured via WebUI (not env vars). Migrated state from igpu compose era:
- **Plex** (tower): `http://192.168.1.2:32400` — no FQDN available (tower/Unraid doesn't have a localProxy-managed record)
- **Jellyfin** (igpu): `https://jelly.ablz.au` — FQDN, follows jellyfin if it moves

### Monitoring sync gotcha

`homelab-monitoring-sync.service` is a oneshot that syncs Nix-declared monitors to Uptime Kuma. Prior to Phase 4, it only ran at boot — `nixos-rebuild switch` without a reboot silently skipped syncing new monitors. This was masked by doc2's nightly auto-update reboots. Fixed in Phase 4 with `RemainAfterExit = true` + `restartTriggers` on the monitor/maintenance JSON derivations.

## Known follow-ups

- **Dashboard migration**: the Immich dashboard from the old compose-era Grafana didn't make it; unrelated to this module but listed in #208.

## Verification after any future change

```
# LAN
curl -s https://jelly.ablz.au/System/Info/Public | jq .

# Tailnet (from any tailnet client)
curl -s https://jellyfinn.ablz.au/System/Info/Public | jq .

# On igpu — check VAAPI encode path is wired
journalctl -u jellyfin --no-pager | grep -i 'vaapi\|hevc_vaapi\|hwaccel'
```

Expect both endpoints to return jellyfin's ServerId + version; journal should mention vaapi/hevc_vaapi encoders as available.

## Related

- `modules/nixos/services/jellyfin.nix` — the module
- `modules/nixos/services/tailscale-share.nix` — the tailnet-share plumbing
- [`tailscale-share.md`](tailscale-share.md) — inter-tailnet share threat model and verification evidence
- `modules/nixos/services/nfs-watchdog.nix` — stale-mount watchdog
- [`media-filesystem.md`](../infrastructure/media-filesystem.md) — mergerfs/virtiofs/tower NFS layout
- [`igpu-passthrough.md`](../infrastructure/igpu-passthrough.md) — `/dev/dri` health + FLR failure mode
- [`tdarr-node.md`](tdarr-node.md) — the other iGPU consumer (both get `/dev/dri`)
