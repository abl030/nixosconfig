---
date: 2026-06-07
topic: backup-coverage-widening
---

# Backup Coverage Widening — Requirements

## Summary

Widen offsite backup coverage beyond photos: add an **immutable Wasabi copy of `/mnt/data/Life`**, put immich's **DB dump into the existing photos bucket**, and add the **curated beets music library to the Synology (mum) repo** — while explicitly leaving re-downloadable and transient data out. Grew out of [#237](https://github.com/abl030/nixosconfig/issues/237) (forgejo dumps → kopia).

## Problem Frame

The fleet has three offsite/secondary backup destinations, but coverage is uneven:

- **Wasabi** (immutable, 90-day Object Lock) backs up **only** the photo library.
- **Synology (mum, over Tailscale)** backs up `/mnt/data/Life`, `Media/Books`, a small `Media/Music` side-set, and the pfSense ZFS replica.
- **doc2 local ZFS** holds the pfSense replica.

The irreplaceable personal data under `/mnt/data/Life` has only the single Synology copy — no jurisdictional/immutable offsite like photos enjoy. Separately, the **real 495 GiB beets music library** and the **doc2 service-state** live only on prom's ZFS with no offsite at all. The existing design already steers irreplaceable data onto `/mnt/data/Life`, so widening is mostly: give `/Life` the same Wasabi treatment photos already have, and cover the curated music on Synology.

## Current backup topology (reference map)

| Destination | Mechanism | What it holds | Immutability |
|---|---|---|---|
| Wasabi S3 (Sydney) | `kopia-photos` | `/mnt/data/Life/Photos/library` | Object Lock Compliance, 90d |
| Mum's Synology (Tailscale NFS → `/mnt/mum`) | `kopia-mum` | `/mnt/data/Life`, `Media/Books`, `Media/Music` (39 GiB side-set), `/mnt/backup/pfsense` | Synology BTRFS snapshots (DSM, not in repo) |
| doc2 local ZFS (`pfsensebackup`) | `syncoid-pfsense` | pfSense pool, daily | sanoid 30d/8w/6m |
| prom ZFS (`nvmeprom/containers`, `…/Music`) | — (no offsite) | all doc2 `/mnt/virtio` state + beets library | none → see [#268](https://github.com/abl030/nixosconfig/issues/268) |

## Key Decisions

- **Wasabi gets all of `/Life`, immutable — but exclude what's already covered or regenerable.** No double-store of the 314 GiB photo library (already in the photos bucket); drop immich's regenerable derivatives; drop the high-churn Unraid USB backup.
- **immich's DB dump rides the existing photos bucket, not the new /Life bucket.** Co-locates the immich catalog with the photos it describes; avoids carrying it in two Wasabi buckets.
- **Music goes to Synology only, never Wasabi.** It is re-downloadable, and 505 GiB at Wasabi's per-GB rate is real monthly cost for data we can re-fetch. Synology grade of protection is sufficient.
- **Never back up the slskd download tree — and never delete it either.** It is transient/re-downloadable, but it is also cratedigger's live working set and slskd's Soulseek share; deletion is off the table.
- **Prom-ZFS-resident service-state is deferred to a ZFS-receiver + PBS design ([#268](https://github.com/abl030/nixosconfig/issues/268)), not bolted onto kopia.** kopia owns tower-NFS-resident data + pfSense; ZFS+PBS will own prom-resident state.
- **The virtiofsd fd-exhaustion fix ([#267](https://github.com/abl030/nixosconfig/issues/267)) is a hard prerequisite** for the music source — kopia walking 100k Music files on the contended virtiofs mount would otherwise re-trigger ENFILE across all doc2 services. Resolved 2026-06-07.

## Requirements

### Wasabi `/Life` (new `kopia-life` instance)

R1. Stand up a new kopia instance `life` writing to a **new Wasabi bucket** with **90-day Object Lock Compliance**, mirroring the `kopia-photos` security model (loopback bind, IAM-scoped keys, `--no-persist-credentials`).

R2. Source `/mnt/data/Life`, daily snapshot at 06:00.

R3. Exclude **all of `/Photos`** (library already in the photos bucket; thumbs/encoded-video/upload regenerable) and **`/Tech/Backups/UnraidUSB`** (the ~4 GiB monthly full-rewrite). Effective coverage ≈ 373 GiB.

### Photos bucket (existing `kopia-photos` instance)

R4. Add `/mnt/data/Life/Photos/backups` (immich's nightly Postgres dumps, ~283 MB/day) as a source on the existing photos instance, so the immich DB lands in the photos Wasabi bucket.

### Music (existing `kopia-mum` instance)

R5. Add `/mnt/virtio/Music` (the whole capital-`Music` dataset — beets library + small staging, ~505 GiB) as a source on kopia-mum (Synology). Do **not** add the lowercase `music/` slskd tree.

R6. Wire kopia-mum's systemd ordering to wait for the `/mnt/virtio` mount and the `Music` submount (the module currently only models `/mnt/data` and `/mnt/mum` dependencies).

### Prerequisite

R7. The [#267](https://github.com/abl030/nixosconfig/issues/267) virtiofsd fix must be live on doc2 before R5/R6 are enabled. **Done 2026-06-07** (verified: fd count flat at ~950 across a 585k-file walk).

### Closeout

R8. Close [#237](https://github.com/abl030/nixosconfig/issues/237): confirm via `kopia source list` that `/mnt/data/Life/Andy/Code/forgejo-dumps` is captured on both `mum` (already) and the new `life` Wasabi repo, and that a recent snapshot contains a representative dump file.

## Scope Boundaries

**Not backed up (intentional):**
- slskd `music/` (~941 GiB) — transient/re-downloadable; do-not-delete (cratedigger + Soulseek share).
- `/mnt/data/Media` video/games/etc (~11 TiB) and `/mnt/mirrors` — re-downloadable/rebuildable.
- immich derivatives (`Photos/{thumbs,encoded-video,upload}`) — regenerable.
- `Tech/Backups/UnraidUSB` — a backup-of-a-backup with high rewrite churn.

**Deferred (not this work):**
- `/mnt/virtio` service-state offsite (mealie, paperless DB, uptime-kuma, tautulli, atuin, etc., ~2.5 GiB irreplaceable) → ZFS-receiver + PBS, [#268](https://github.com/abl030/nixosconfig/issues/268).

## Dependencies / Assumptions

- **#267 fix live** (done) — without it, R5's backup walk re-triggers virtiofsd ENFILE for all doc2 services.
- **Wasabi billing is per-GB** (pay-as-you-go; no 1 TB floor). The `life` bucket (~373 GiB) is the new cost — roughly $2.5–3/mo at Wasabi's per-GB rate; the immich DB dumps add ~25 GiB at 90-day retention. Wasabi's 90-day minimum-storage-duration aligns with the 90-day Object Lock, so churned/replaced data is billed for 90 days regardless — which is exactly why the high-churn `UnraidUSB` dir is excluded and the 505 GiB music tree goes to Synology, not Wasabi.
- **Synology capacity** for +505 GiB of music.
- **Object Lock can't be enabled after bucket creation** — the `life` bucket must be created with it on (same lesson as the photos bucket).

## Outstanding Questions

**Resolve before planning:** none — Wasabi billing confirmed per-GB; the ~$3/mo for the `life` bucket is accepted.

**Deferred to planning:**
- Keep or drop the now-redundant 39 GiB `/mnt/data/Media/Music` side-set source on kopia-mum once the real library is covered.
- `life` bucket name, IAM policy (mirror the `kopiaphotos` scoped JSON), and Object Lock retention config.
- Optional slskd concurrency cap as defense-in-depth for #267.

## Acceptance Examples

AE1. **Covers R1–R3, R8.** `kopia source list` on the `life` repo shows `/mnt/data/Life`; a snapshot contains a representative forgejo dump and does **not** contain `Photos/library` or `Tech/Backups/UnraidUSB`.

AE2. **Covers R4.** `kopia source list` on `photos` shows `/mnt/data/Life/Photos/backups`; a snapshot contains a recent `immich-db-backup-*.sql.gz`.

AE3. **Covers R5–R7.** After enabling the Music source, a backup walk completes with no ENFILE and doc2's containers virtiofsd fd count stays low; `kopia source list` on `mum` shows `/mnt/virtio/Music` with a fresh snapshot.

## Sources / Research

- **`/Life` churn audit (2026-06-07):** 862 GiB total, only ~31 GiB changed in 90 days. Movers: Photos growth (~10 GiB/mo, additive, library already in Wasabi), `Tech/Backups/UnraidUSB` (5 GiB/mo full-rewrite), `Andy/Genealogy` (3.8 GiB, many small files). Retention "tax" of one immutable bucket ≈ the UnraidUSB churn only → trivial, so exclusions beat a second looser-retention bucket.
- **`/mnt/virtio` audit:** 1.45 TiB total; dominated by `music/` slskd (941 GiB) + `Music/` beets (505 GiB, of which Beets = 495 GiB). Irreplaceable not-otherwise-covered service-state ≈ 2.5 GiB.
- **Photos internals:** library 314 GiB (in Wasabi), encoded-video 146, thumbs 18, upload 2.6 (regenerable), `backups/` 3.9 GiB = immich DB dumps (the bit to keep).
- Related: [#237](https://github.com/abl030/nixosconfig/issues/237), [#267](https://github.com/abl030/nixosconfig/issues/267), [#268](https://github.com/abl030/nixosconfig/issues/268). Modules: `modules/nixos/services/kopia.nix`, `hosts/doc2/configuration.nix`. Wiki: `docs/wiki/services/kopia.md`, `docs/wiki/infrastructure/virtiofsd-fd-exhaustion.md`.
