# Virtiofs database-state performance and doc2 LXC strategy

**Date:** 2026-07-25
**Status:** benchmarked and audited; architecture recommendation only, no production migration performed
**Issues:** [#51](https://git.ablz.au/abl030/nixosconfig/issues/51) (nested virtiofs fault), [#53](https://git.ablz.au/abl030/nixosconfig/issues/53) (database-state exit)
**Related:** [issue51-virtiofs-investigation.md](issue51-virtiofs-investigation.md), [virtiofs-nested-reexport-stale-pins.md](virtiofs-nested-reexport-stale-pins.md), [containers-backup-restore.md](containers-backup-restore.md)

## Executive conclusion

Production database state on doc2 should move off QEMU virtiofs. The preferred architecture to prototype is now **doc2 as an unprivileged NixOS LXC with host ZFS datasets bind-mounted directly into it**, not merely the existing VM with more block disks.

The LXC lab established three points:

1. Direct bind mounts eliminate QEMU virtiofs and preserve host-side dataset visibility.
2. Native ZFS `recordsize=4K` or `8K` materially improves database-shaped I/O over the current inherited 128K geometry. In the clean low-QD round, 4K led mixed throughput and writes; 8K led reads and p99 latency.
3. On the **exact same aged ext4 filesystem and 64K zvol**, LXC beat VM in both run orders. LXC delivered 15% and 47% more QD4 mixed IOPS in the paired controls, with equal or lower p99 latency.

The earlier fresh 64K VM-zvol result of 36,526 mixed IOPS and 0.21/0.24 ms p99 did **not** reproduce on the same populated filesystem. It was a useful fresh sparse-volume result, but it is not a steady-state architecture claim and must not be used to say that VM block is 6.25x faster than virtiofs in production.

This benchmark does not by itself authorize converting doc2. The NixOS LXC prototype must first prove unprivileged operation, service compatibility, nested-container removal or support, networking, device access, backup/restore, observability, and rollback. If that prototype fails, dedicated 64K zvol/ext4 VM disks remain the fallback; direct virtiofs is not the database-state target.

## Why this was investigated

Issue #51 proved that nested/re-exported virtiofs is unsound for slskd's hot paths. Issue #53 originally tracked only that de-nesting decision. The follow-up storage comparison exposed a larger fleet concern: doc2's normal service-state convention puts nearly every production database behind a direct QEMU virtiofs mount.

The investigation expanded to answer:

1. Is direct virtiofs a poor database transport as well as a correctness risk at the nested seam?
2. Is the existing `nvmeprom` VM-zvol geometry appropriate for database state?
3. Would an LXC with direct host bind mounts provide a better path?
4. Which native-ZFS `recordsize` is promising for database datasets?
5. Which production databases currently traverse virtiofs?
6. How should critical and rebuildable state, backups, and rollback be separated?

## Storage paths are not interchangeable

Current doc2 VM path:

```text
application / nspawn database on doc2
  -> /mnt/virtio or /mnt/mirrors
  -> QEMU virtiofs
  -> prom virtiofsd
  -> native nvmeprom dataset
  -> three-wide NVMe RAIDZ1
```

VM block fallback:

```text
application / database on doc2
  -> ext4
  -> virtio-SCSI
  -> QEMU
  -> 64K ZFS zvol
  -> three-wide NVMe RAIDZ1
```

Preferred LXC prototype:

```text
application / database in doc2 LXC
  -> direct Proxmox bind mount
  -> native per-class ZFS dataset
  -> three-wide NVMe RAIDZ1
```

LXC ext4 control path:

```text
fio in LXC
  -> direct bind of host-mounted ext4
  -> 64K ZFS zvol
  -> three-wide NVMe RAIDZ1
```

These are four different architectures despite several containing `virtio`, ZFS, or bind mounts.

Jellyfin already uses the native-ZFS/LXC topology: prom bind-mounts `/nvmeprom/containers/jellyfin` into igpu CT 107. Its dataset currently inherits `recordsize=128K`; the LXC results make a dedicated smaller-recordsize migration worth testing, but populated datasets cannot be retuned in place.

## Benchmark controls

All tests used disposable paths on prom. No production service or production dataset was benchmarked.

Common conditions:

- backing pool: `nvmeprom`, three-wide NVMe RAIDZ1, `ashift=12`
- direct I/O
- incompressible/refilled buffers
- metadata-only ARC caching for benchmark objects
- compression disabled on scratch datasets/zvol
- 8 GiB saturation files
- fio 4K random phases and 1 MiB sequential phases
- `end_fsync=1` on write phases
- 90-second idle reset before each controlled candidate
- rotated candidate order where repeated rounds were run

Lab guests:

- VM 951: issue #51 NixOS lab VM, 15 vCPU, 24 GiB RAM, `virtio-scsi-single`
- CT 953: disposable Debian 13, **unprivileged**, 8 vCPU, 8 GiB RAM

LXC-native candidates were direct binds of scratch ZFS datasets with `recordsize` 4K, 8K, 16K, 32K, 64K, and 128K. The LXC ext4 candidate was a host-mounted ext4 filesystem on a sparse 16 GiB 64K zvol, bind-mounted directly into CT 953.

The ext4 filesystem was then detached from the host/LXC and attached unchanged to VM 951 for same-filesystem A/B testing. UUID, filesystem, zvol, and persistent test file were held constant.

## Methodology correction

The first LXC low-QD phases ran immediately after a 128-deep saturated random-write phase. The earlier VM low-QD test had instead started after an idle reset and clean sequential preparation. Those LXC low-QD values were order-confounded and are not used below.

A clean low-QD suite was rerun for every LXC candidate with:

1. 90-second pool idle reset
2. 4 GiB sequential preparation plus final fsync
3. QD1 4K random read
4. QD1 4K random write plus final fsync
5. QD4 70/30 mixed random I/O plus final fsync

This correction matters more than preserving a flattering headline. The fresh VM 64K result also failed to reproduce once the exact same populated filesystem was compared between VM and LXC. It is retained below as historical evidence of fresh sparse-volume behavior, not as the steady-state result.

## VM zvol-size experiment

The earlier controlled post-idle VM saturation round used fresh ext4 filesystems on 16K, 32K, 64K, and 128K zvols:

| `volblocksize` | Sequential read | Sequential write | 4K random read | 4K random write | Write p99 |
|---|---:|---:|---:|---:|---:|
| 16K (current default) | 6,765 MiB/s | 3,428 MiB/s | 56,391 IOPS | 5,546 IOPS | 187.7 ms |
| 32K | 5,911 MiB/s | 3,059 MiB/s | 158,421 IOPS | 13,675 IOPS | 62.7 ms |
| 64K | 4,727 MiB/s | 3,115 MiB/s | 192,100 IOPS | 26,658 IOPS | 47.4 ms |
| 128K | 6,496 MiB/s | 2,982 MiB/s | 105,311 IOPS | 11,596 IOPS | 67.6 ms |

This still supports 64K as the measured general-purpose geometry for **new VM zvols on this pool**. It does not establish a native-ZFS `recordsize` and does not convert existing populated zvols in place.

The first fresh-volume low-QD round was:

| `volblocksize` | QD1 read | QD1 write | QD4 70/30 mixed | Mixed p99 read/write |
|---|---:|---:|---:|---:|
| 16K | 6,015 IOPS | 4,922 IOPS | 9,807 IOPS | 4.69 / 4.69 ms |
| 32K | 7,670 IOPS | 8,370 IOPS | 26,963 IOPS | 1.52 / 1.53 ms |
| 64K | 8,282 IOPS | 8,385 IOPS | 36,526 IOPS | 0.21 / 0.24 ms |
| 128K | 6,970 IOPS | 7,576 IOPS | 17,632 IOPS | 2.54 / 2.57 ms |

The 64K row is a real measured result, but the same 64K ext4 filesystem later delivered 12,336-12,630 mixed IOPS in VM 951 after allocation and random-write history. Treat 36,526 as a fresh sparse-volume burst, not a durable production expectation.

## LXC native-ZFS results

### Saturation and sequential means

Two rotated rounds were run for each native dataset. Values below are means of both rounds.

| Native ZFS `recordsize` | Seq read | Seq write | 4K random read | 4K random write |
|---|---:|---:|---:|---:|
| 4K | 1,004 MiB/s | 476 MiB/s | 67,609 IOPS | 78,590 IOPS |
| 8K | 1,330 MiB/s | 737 MiB/s | 62,732 IOPS | 38,113 IOPS |
| 16K | 1,883 MiB/s | 1,208 MiB/s | 47,608 IOPS | 26,882 IOPS |
| 32K | 2,099 MiB/s | 1,723 MiB/s | 48,212 IOPS | 15,093 IOPS |
| 64K | 3,027 MiB/s | 2,227 MiB/s | 38,949 IOPS | 8,874 IOPS |
| 128K | 3,836 MiB/s | 2,293 MiB/s | 25,703 IOPS | 6,433 IOPS |

The expected trade-off is clear: smaller records favor small random writes; larger records favor streaming. There is no universal native-ZFS record size.

### Corrected clean low-QD round

| Candidate | Prep write | QD1 read | QD1 write | QD4 70/30 mixed | Mixed p99 read/write |
|---|---:|---:|---:|---:|---:|
| Native ZFS 4K | 295 MiB/s | 13,254 IOPS | **30,465 IOPS** | **16,261 IOPS** | 0.70 / 0.68 ms |
| Native ZFS 8K | 550 MiB/s | **17,513 IOPS** | 10,476 IOPS | 14,795 IOPS | **0.33 / 0.33 ms** |
| Native ZFS 16K | 536 MiB/s | 10,150 IOPS | 5,530 IOPS | 8,862 IOPS | 3.10 / 3.10 ms |
| Native ZFS 32K | 1,593 MiB/s | 10,211 IOPS | 10,780 IOPS | 13,039 IOPS | 0.45 / 0.45 ms |
| Native ZFS 64K | 557 MiB/s | 7,578 IOPS | 4,407 IOPS | 6,852 IOPS | 3.56 / 3.52 ms |
| Native ZFS 128K | 2,209 MiB/s | 6,443 IOPS | 6,094 IOPS | 5,517 IOPS | 3.92 / 3.95 ms |
| LXC ext4 / 64K zvol | 3,622 MiB/s | 8,700 IOPS | 7,437 IOPS | 14,538 IOPS | 3.49 / 3.56 ms |

For database datasets:

- **8K is the balanced starting point** for PostgreSQL-like state: strongest QD1 reads, lowest p99, better sequential behavior than 4K, and only 9% less mixed throughput than 4K.
- **4K is the write-heavy/SQLite candidate:** strongest QD1 and saturated writes and highest mixed IOPS, at substantial sequential cost.
- **32K deserves workload-specific consideration** when streaming and database I/O coexist, but should not be inferred from page size alone.
- 64K and 128K native records are poor defaults for the tested 4K database-shaped workload.

These are dataset-creation candidates, not in-place property changes. Existing populated datasets require a new dataset and a quiesced copy/migration to change effective record geometry.

## Exact same-filesystem LXC versus VM

The ext4 filesystem on `nvmeprom` 64K zvol was used unchanged in both guests. Two paired controls reversed execution order.

### Pair A: LXC first, VM second

Each path ran the clean low-QD suite with a 4 GiB prepared file.

| Path | QD1 read | QD1 write | QD4 mixed | Mixed p99 read/write |
|---|---:|---:|---:|---:|
| LXC direct bind | 8,700 | 7,437 | 14,538 | 3.49 / 3.56 ms |
| VM virtio-SCSI | 6,109 | 2,553 | 12,630 | 3.59 / 3.59 ms |

LXC delivered 15% more mixed IOPS.

### Pair B: VM first, LXC second

Both paths used the same already allocated persistent 8 GiB file; no preparation or deletion occurred between paths.

| Path | QD1 read | QD1 write | QD4 mixed | Mixed p99 read/write |
|---|---:|---:|---:|---:|
| VM virtio-SCSI | 6,023 | 4,054 | 12,336 | 3.29 / 3.33 ms |
| LXC direct bind | 7,988 | 6,839 | 18,092 | 2.44 / 2.44 ms |

LXC delivered 47% more mixed IOPS and about 26% lower p99 latency.

The magnitude varied with allocation/COW history, but the direction did not: LXC was faster in both run orders. Averaged only as a directional summary across the two different paired controls, LXC produced 38% more QD1 reads, 2.16x the QD1 writes, 31% more mixed IOPS, and about 13% lower p99 latency.

This does not prove every application will be faster in LXC. It does establish that LXC bind mounting is not the bottleneck and that QEMU/virtio-SCSI did not outperform the direct bind path on the same filesystem.

## Direct virtiofs context

The earlier isolated direct-virtiofs low-QD result was:

| Workload | Direct virtiofs |
|---|---:|
| QD1 4K read | 6,613 IOPS |
| QD1 4K write | 3,858 IOPS |
| QD4 70/30 mixed | 5,840 IOPS |
| Mixed read p99 | 3.39 ms |
| Mixed write p99 | 5.14 ms |

Both corrected LXC database candidates materially exceeded virtiofs mixed throughput:

- native ZFS 4K: 16,261 mixed IOPS, 2.78x virtiofs
- native ZFS 8K: 14,795 mixed IOPS, 2.53x virtiofs
- LXC ext4 clean run: 14,538 mixed IOPS, 2.49x virtiofs

Do not compare the fresh VM 36,526 result directly to virtiofs as a stable production ratio. The architecture decision rests on the corrected and same-filesystem controls.

## Live production database inventory

The audit combined declarative module paths, live mount topology, active nspawn units, privileged filename-only database discovery, and on-disk usage. Database contents and credentials were not read.

### Nspawn databases on direct virtiofs

All nine live doc2 database containers traverse QEMU virtiofs.

Under `/mnt/virtio`:

| Database | Engine | Host-side tree |
|---|---|---|
| Immich | PostgreSQL | `/mnt/virtio/immich/postgres` |
| Cratedigger | PostgreSQL | `/mnt/virtio/cratedigger/postgres` |
| Jellystat | PostgreSQL | `/mnt/virtio/jellystat/postgres` |
| Atuin | PostgreSQL | `/mnt/virtio/atuin/postgres` |
| Paperless | PostgreSQL | `/mnt/virtio/paperless/postgres` |
| Mealie | PostgreSQL | `/mnt/virtio/mealie/postgres` |
| Youtarr | MariaDB | `/mnt/virtio/youtarr/mariadb-nspawn` |

These seven consume about **1.58 GiB** physically.

Under `/mnt/mirrors`:

| Database | Engine | Host-side tree |
|---|---|---|
| MusicBrainz | PostgreSQL | `/mnt/mirrors/musicbrainz/postgres-nspawn/postgres` |
| Discogs | PostgreSQL | `/mnt/mirrors/discogs/postgres` |

These two re-downloadable databases consume about **49.68 GiB** physically.

### Embedded and index state on doc2 virtiofs

The live scan also found Mailsearch SQLite/vector/Xapian state, Beets SQLite, Uptime Kuma SQLite/WAL, Tautulli, Watchstate, Komga, Forgejo, Grafana, Audiobookshelf, Overseerr and Gotify SQLite, UniFi MongoDB, Loki index/WAL/chunks, and Paperless Celery state.

The explicitly identified database set is about **53 GiB** before all Loki, MongoDB, surrounding application state, and growth headroom are counted.

### Different topologies

- **Jellyfin:** direct prom ZFS -> igpu LXC bind, not virtiofs. Its inherited 128K record size is now a measured tuning candidate, but still needs service-specific testing.
- **slskd:** nested/re-exported virtiofs and the original #51 correctness problem. Its redesign remains related but is not the primary #53 scope.
- **doc2 root:** ext4 on an existing 16K zvol. It is block storage, but it lacks capacity for the audited database estate and is not the preferred consolidation target.

## Recommended architecture

### Preferred: prototype doc2 as an unprivileged LXC

Build a parallel disposable NixOS LXC from the doc2 configuration. Do not convert or delete VM 114 in place.

Recommended storage shape:

- direct host bind mounts, not QEMU virtiofs
- separate native ZFS datasets by workload and recovery class
- 8K starting record size for PostgreSQL-like critical database datasets
- 4K candidate for SQLite and write-heavy state after application-level validation
- larger-record datasets for bulk media, uploads, backups, and streaming workloads
- critical and rebuildable data in different backup domains
- no blanket recursive inclusion of mirrors/indexes in critical backups

The database result does not imply that every service root belongs on an 8K dataset. Expose `databaseDir`, `cacheDir`, `mediaDir`, or equivalent where one broad `dataDir` currently combines incompatible workloads.

### Required LXC feasibility gates

The benchmark used a minimal unprivileged Debian CT, not the doc2 NixOS workload. Before migration, prove:

1. NixOS boots and updates correctly as an unprivileged Proxmox LXC.
2. Existing systemd/nspawn database containers are removed, flattened into the LXC, or shown to work safely with bounded nesting. Do not silently choose a privileged CT to preserve nesting.
3. Podman/OCI services retain cgroup delegation, network isolation, firewall behavior, DNS, and image/runtime hardening.
4. TUN/Tailscale, FUSE if needed, `/dev` access, timers, journald forwarding, node exporter, and LGTM telemetry work.
5. UID/GID mappings, ACLs, xattrs, hardlinks, sparse files, and service ownership survive direct bind mounts.
6. Bind-mounted critical datasets have tested independent backup and restore. Proxmox LXC backup does not automatically make arbitrary host bind mounts safe.
7. Rebuildable mirrors/indexes remain excluded from expensive backups.
8. The existing VM remains an intact rollback target until the LXC passes real reads/writes and a soak period.
9. Network identity cutover is staged so VM and LXC never claim the same address simultaneously.
10. Host-kernel sharing and the changed isolation boundary are explicitly accepted.

### Fallback: keep doc2 as a VM

If the LXC compatibility or security gates fail:

- create dedicated sparse 64K zvol/ext4 disks
- use `virtio-scsi-single`, dedicated iothreads, `cache=none`, discard, and SSD semantics
- separate critical (`backup=1`) from rebuildable (`backup=0`) state
- keep logical database dumps in addition to crash-consistent VM/PBS coverage
- move database paths off virtiofs one service at a time

The VM fallback remains materially cleaner than database files on virtiofs, but the 36,526 fresh-volume result must not be used as its steady-state performance promise.

## Migration and rollback

This is a design sequence, not authorization to migrate production.

1. Build the parallel doc2 LXC and satisfy every feasibility gate.
2. Define critical, rebuildable, and bulk datasets declaratively with explicit record sizes, ownership, backup policy, and mount mappings.
3. Start with Youtarr or another small, low-risk database.
4. Confirm a current logical dump and restoration procedure.
5. Stop every writer and the database cleanly.
6. Copy the quiesced tree while preserving ownership, modes, ACLs, xattrs, sparse extents, and hardlinks where relevant.
7. Start the database and verify internal recovery, schema ownership/invariants, and clean logs.
8. Start the consumer and exercise real reads and writes.
9. Verify monitoring and backup/restore coverage.
10. Retain the old source read-only for an explicit rollback period.
11. Move one unproven critical database at a time.
12. Migrate control-plane state such as Forgejo and UniFi only after the pattern is established.
13. Move rebuildable MusicBrainz, Discogs, Loki, and Mailsearch data only after backup exclusions are confirmed.
14. Cut over doc2 network identity only after service-level and whole-node validation.
15. Keep VM 114 intact until the LXC has completed an agreed soak period.

## Cleanup and retained evidence

The benchmark created only disposable resources:

- CT 953 and its temporary root filesystem
- `nvmeprom/issue53-lxc-lab` and six recordsize child datasets
- temporary 16 GiB 64K zvol, later named `nvmeprom/vm-951-disk-7`
- host and guest mounts, fio files/scripts, and result archives
- temporary VM 951 SCSI attachment

After raw JSON was copied locally and summarized:

- CT 953 was destroyed
- every scratch dataset and zvol was destroyed
- all host and guest mounts were removed
- VM 951's test disk and unused reference were removed
- VM 951 was restarted healthy with its original `virtio0` boot disk only
- no production Proxmox storage, service, backup, or data path was changed

Production implementation remains a separately reviewed project under #53.
