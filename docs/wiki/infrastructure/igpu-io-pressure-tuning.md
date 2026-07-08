# igpu LXC — disk I/O pressure (PSI) from Jellyfin scans

**Researched:** 2026-07-08
**Status:** Diagnosed / benign. One repo tweak applied (`dropcacheonclose=false`); rest are documented options.
**Hosts:** `igpu` (LXC **CT 107** on `prom`), Jellyfin.
**See also:** [igpu-lxc-migration](igpu-lxc-migration.md) · [media-filesystem](media-filesystem.md) · [prom-hypervisor](prom-hypervisor.md) · [services/jellyfin](../services/jellyfin.md)

## Symptom

`prom` shows sustained **I/O pressure-stall (PSI)** — `io full avg300 ≈ 8-9%` at the host, and **`≈ 17-22%` inside the `igpu` LXC's cgroup** (`/sys/fs/cgroup/lxc/107/io.pressure`). CPU and memory pressure are ~0, so it is **purely disk-I/O latency**, not compute or RAM.

The container-level number is what surfaces on dashboards as "igpu (lxc)". It bubbles up to the host figure because ZFS issues the actual disk I/O from its own kernel threads.

## Root cause

It is **latency-bound small random reads on a raidz1 vdev**, driven by **Jellyfin's media analysis / trickplay / keyframe extraction**.

- Peak throughput during the stall was only **~14 MB/s** — trivial for 3× Samsung 990 Pro NVMe. PSI measures *time stalled waiting on I/O*, and the workload is ~294k small (~19 KB) random read-IOs per drive plus ~2.6 GB of metadata writes.
- The active process caught was `ffprobe -skip_frame nokey -show_entries format=duration …` — Jellyfin's **`FfProbeKeyframeExtractor`** (the keyframe-index walk feeding trickplay / HLS media-segments), running against media through mergerfs.
- **raidz1 has single-disk random-read IOPS** (a logical read can touch all data disks; the vdev queue depth is effectively one disk's worth for random work). Parallel scan workers pile onto that one queue → the whole cgroup blocks (`io full`).
- **mergerfs `cache.files=off` + `dropcacheonclose=true`** meant every scan pass re-read from the backend with no page-cache reuse — Jellyfin makes *several* consecutive passes over each file (duration → keyframe → trickplay), each one cold.

## Live ground-truth (from `prom`, 2026-07-08)

Verified on the hypervisor — corrects several first-glance assumptions:

- **ARC is fine:** `zfs_arc_max = 12.34 GiB` (PVE's 10%-of-RAM default), ARC full, **99.7% lifetime hit ratio**, ~4.3 GiB metadata. Host has 123 GB RAM with ~46 GB free + ~41 GB reclaimable buff/cache — lots of headroom to raise the cap.
- **recordsize = 128K** on `nvmeprom/containers` and all children (not 1M). A 19 KB read amplifies to a 128K record, not 1M — read-amp is already modest; **recordsize is a non-issue.**
- **atime = on but relatime = on** on every dataset → atime writes throttled to ~1/day/file, not per-read.
- **Pool health:** `nvmeprom` ONLINE, 0 errors, last scrub clean, 39% frag. No SLOG / special / L2ARC vdev.
- **Jellyfin config is jellyfin-owned (imperative), NOT NixOS-managed** except `encoding.xml` (via `forceEncodingConfig`). Live state: `LibraryScanFanoutConcurrency=0` (auto → 8), `ParallelImageEncodingLimit=0`, trickplay `EnableKeyFrameOnlyExtraction=false`, per-library (Movies+Shows) `ExtractTrickplayImagesDuringLibraryScan=true` (trickplay runs **inline with every scan**), `EnableChapterImageExtraction=true` but `ExtractChapterImagesDuringLibraryScan=false` (deferred to the 02:00 task — good), `EnableLUFSScan=true` (reads the whole audio track of every video). Music library already has trickplay/chapters off.

## Levers — ranked (impact × ease ÷ risk)

### 1. Jellyfin: cap scan concurrency — **best easy win** (imperative, API) — **APPLIED 2026-07-08**
Set **`LibraryScanFanoutConcurrency = 2`** (UI label: "Parallel library scan tasks limit"; was `0`/auto = up to 8 on this 8-core CT). Serialises the read pile-up on the single raidz1 queue into a near-sequential stream, flattening the `io full` peak. Jellyfin's own docs recommend lowering this on network/FUSE filesystems. Reversible; scans just take longer in wall-clock.

Jellyfin config is **jellyfin-owned, not NixOS-managed**, so this is set via the REST API (no restart needed) rather than the repo. Reuse the existing soularr Jellyfin key (doc1 holds the sops editor key):

```sh
# from secrets/ on doc1:
TOK=$(sops -d hosts/doc2/soularr.env | sed -n 's/^JELLYFIN_TOKEN=//p')
curl -s -H "X-Emby-Token: $TOK" https://jelly.ablz.au/System/Configuration -o cfg.json
jq '.LibraryScanFanoutConcurrency = 2' cfg.json \
  | curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "X-Emby-Token: $TOK" \
      -H 'Content-Type: application/json' --data @- https://jelly.ablz.au/System/Configuration   # -> 204
```

Siblings `LibraryMetadataRefreshConcurrency` and `ParallelImageEncodingLimit` left at auto (`0`) — set them to 2 the same way if pressure persists during metadata refresh / image (trickplay) encoding.

### 2. ~~Raise `zfs_arc_max` on `prom`~~ — **RULED OUT (prom is memory-pressured at times)**
Raising the ARC cap would lower per-read latency, but **`prom` runs under memory pressure at times**, so stealing more RAM for ARC is off the table for this host. **Do NOT bump `zfs_arc_max`** — leave PVE's 10% cap. (Revisit only if prom's memory headroom structurally changes.)

### 3. mergerfs: stop purging the page cache — **the clean repo change (APPLIED 2026-07-08)**
`modules/nixos/services/mounts/fuse.nix` `baseFlags`: **`dropcacheonclose=true` → `false`.** With `cache.files=off`, mergerfs otherwise `posix_fadvise(DONTNEED)`s the underlying branch file on every close, so Jellyfin's back-to-back passes each re-read from the backend. `false` lets passes 2..N hit the guest page cache. trapexit's own recommendation for kernel ≥6.6 with `cache.files=off`. Cost: bounded guest page-cache RAM on the 16 GB CT (kernel evicts under pressure). Deploy: signed commit → `fleet-deploy igpu`.
- **Optional follow-up (separate decision — has a staleness tradeoff):** add `cache.attr=60,cache.entry=60,cache.readdir=true` to cut the getattr/lookup storm while enumerating ~100k files. Downside: up to 60 s stale visibility of files written *directly on a branch* by the arr stack on tower — harmless for a media library but a real semantic change, so not bundled with the above.

### 4. Jellyfin: make per-file work cheaper / off-peak (imperative, UI)
- Trickplay → **"Only generate images from key frames" = ON** — ~60-110× faster extraction (skips decoding non-keyframes), collapsing the pressure window. Caveat: incompatible decoders fall back to software; a known ffmpeg open-GOP H.264 bug can error some files with no auto-fallback yet — verify trickplay still completes after enabling.
- Per-library (Movies+Shows) → **"Extract trickplay images during the library scan" = OFF** — defers trickplay to the scheduled task so routine scans finish fast and the heavy I/O lands off-peak.
- Per-library (Movies+Shows) → **"Enable LUFS scan" = OFF** — currently reads the entire audio track of every video (a music feature); unnecessary whole-file reads on video libraries.
- Optional container env `JELLYFIN_FFmpeg__probesize=50M` caps per-file analysis reads (default 1G).

### 5. `atime=off` on the media datasets (imperative on prom) — marginal
`zfs set atime=off nvmeprom/containers/media_metadata nvmeprom/containers/Music`. Eliminates the once-per-scan atime CoW rewrite. Marginal because relatime already caps it; free and instant.

## First, decide whether this is even recurring (5-min diagnostic)

Jellyfin **10.11 prunes + regenerates trickplay/keyframe/chapter/subtitle data whenever a file's mtime OR size changes** (PR #14674, made more aggressive in #14984; the opt-out `FileChangeRequireSizeChange` PR #14716 is still **unmerged** in 10.11.11). On FUSE/mergerfs/NFS-backed media this is a documented cause of endless regeneration loops.

- **If media file mtimes are stable across scans** → this is one-time backfill, and "leave it alone" is correct.
- **If anything churns mtimes** (arr renames, `mkvpropedit`, mergerfs policy moves, NFS attr-time granularity) → Jellyfin re-does the full keyframe/trickplay work every cycle, and *that's* the real bug — fix mtime stability upstream, not the disk.

Check: `stat` a few Movies files before/after a scan; watch whether the "Generate Trickplay Images" / keyframe task keeps finding work.

## NOT worth it (verified wrong or irreversible for this workload)

- **Special (metadata) vdev** — device removal is **impossible on any pool containing a raidz vdev**, so adding it is permanent (undo = destroy/recreate the pool). Only captures newly-written metadata, needs its own mirror, marginal over raising ARC. **Do not.**
- **L2ARC / `secondarycache`** — same NVMe class as the pool (no faster tier), and a once-per-scan cold walk barely warms it. Raise ARC instead.
- **SLOG / `logbias` / `sync=disabled`** — this is a **read** problem; the metadata writes are async and never touch the ZIL. No gain, only risk.
- **`primarycache=metadata`** — actively harmful; forces every data read to re-fetch the full record from disk (documented media-server regressions). Leave at `all`.
- **`recordsize` change** — only applies to newly-written files, and 128K is already fine here. No-op.
- **cgroup `io.max`/`io.weight` / systemd `IOReadIOPSMax=` / `ionice` on the container** — **do not work on ZFS.** ZFS issues disk bios from its own zio kernel threads in the root cgroup, bypassing blk-cgroup (openzfs #1952, confirmed by Proxmox staff for LXC+ZFS+bind-mounts). NVMe uses the `none` scheduler, so `ionice` is doubly dead. The only working throttle is Jellyfin's own concurrency knobs (#1).

## Verdict

The pool is healthy and the stall is intermittent, purely the shape of latency-bound small reads on a raidz1 vdev. **No hardware change is warranted.** The highest-leverage, fully-reversible move — Jellyfin **`LibraryScanFanoutConcurrency = 2`** — is **applied** and directly targets `io full`. The ARC bump is **ruled out** (prom memory pressure). The one repo-declarative change (`dropcacheonclose=false`, applied) helps Jellyfin's multi-pass re-reads. Everything else is polish. But first confirm media mtimes are stable — if they are, this is one-time backfill and leaving it alone is exactly right.

## When to revisit

- If PSI is chronic (not just during a known scan) → run the mtime diagnostic; suspect Jellyfin 10.11 prune-on-change.
- If `FileChangeRequireSizeChange` (PR #14716) merges upstream → enable it to stop mtime-triggered regeneration.
- Re-measure after the `LibraryScanFanoutConcurrency=2` + `dropcacheonclose=false` changes: `cat /sys/fs/cgroup/lxc/107/io.pressure` on `prom` during a scan.
