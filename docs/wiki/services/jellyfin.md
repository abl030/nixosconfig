# Jellyfin (native, on igpu)

**Last updated:** 2026-04-15
**Status:** working
**Host:** `igpu` (VM 109)
**Owner:** `modules/nixos/services/jellyfin.nix` under `homelab.services.jellyfin`
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208) (Phase 3)

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

Single root-owned parent (`dataRoot`, default `/mnt/virtio/jellyfin`) so jellyfin-owned children (`data/`, `config/`, `log/`) and root-owned children (`ts/`) can coexist without systemd-tmpfiles "unsafe path transition" errors:

```
/mnt/virtio/jellyfin/       root:root 0755  ← dataRoot (pre-created via tmpfiles.rules mkBefore)
├── data/                   jellyfin:jellyfin 0750  — --datadir: libraries.db, plugins, metadata
├── config/                 jellyfin:jellyfin 0750  — --configdir: system.xml / network.xml / ...
├── log/                    jellyfin:jellyfin 0750  — --logdir
└── ts/                     root:root 0755          — homelab.tailscaleShare.jellyfin state
```

`/var/cache/jellyfin` stays on local igpu storage (regenerable; not worth virtiofs).

See [media-filesystem.md](../infrastructure/media-filesystem.md) for the mergerfs layout that backs `/mnt/fuse/Media/{Movies,TV_Shows,Music}`.

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
- Re-add a Music path (`<Path>/mnt/fuse/Media/Music</Path>`) and create `Music.mblink` containing `/mnt/fuse/Media/Music` — the Music library's `PathInfos` was empty after some earlier edit attempt

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
| Data | `/mnt/virtio/jellystat/{backup-data,postgres}` (abl030:users except pg internal) |
| Kuma monitor | `https://jellystat.ablz.au/` |

Container runs as `--user=1000:100` so host-side files land abl030-owned. Connects to nspawn PG via podman MASQUERADE (source IP rewritten to 192.168.100.14, matching pg_hba trust rule).

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
| Data | `/mnt/virtio/watchstate` mounted as `/config` (abl030:users) |
| Kuma monitor | `https://watchstate.ablz.au/` |

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
- `modules/nixos/services/nfs-watchdog.nix` — stale-mount watchdog
- [`media-filesystem.md`](../infrastructure/media-filesystem.md) — mergerfs/virtiofs/tower NFS layout
- [`igpu-passthrough.md`](../infrastructure/igpu-passthrough.md) — `/dev/dri` health + FLR failure mode
- [`tdarr-node.md`](tdarr-node.md) — the other iGPU consumer (both get `/dev/dri`)
