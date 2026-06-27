# Unraid NFS user-share stale file handles (shfs ESTALE / "fileid changed")

**Researched / acted:** 2026-06-26 · **Status:** known structural Unraid behaviour — mitigated, not
"fixed" (can't be, without changing storage topology). · **Triggered by:** the 2026-06-26 qBittorrent
incident (the 47 GB "Curb Your Enthusiasm" pack kept erroring at ~0.4 %).

This is the *why* behind the NFS stale-handle errors that hit anything mounting a tower **user share**
(`/mnt/user/*`) over NFS — `servarr`'s `/media/data`, doc2's `/mnt/data` (`homelab.mounts.nfsLocal`),
and in principle any fleet NFS consumer of tower. Rules in code: the NFS mount modules under
`modules/nixos/services/mounts/` (`nfs-local.nix` = the static server pattern). The tower-side knob
(`fuse_remember`) is **Unraid flash config, NOT in this Nix repo** — see "What we changed" below.

## TL;DR

`NFS: server 192.168.1.2 error: fileid changed` → `Stale file handle` (ESTALE) on an Unraid `/mnt/user`
mount is a **well-known, structural** Unraid problem, not our misconfiguration and not a regression. An
NFS file handle's *fileid* **is** the inode number; Unraid `/mnt/user/*` is a **FUSE union (`shfs`)**
that hands out **synthetic, non-stable inode numbers**. When shfs forgets and re-derives an inode (idle
expiry via the `fuse_remember` timer, the Mover relocating a file across disks, or a forced re-mount),
the fileid under a client's held handle changes → ESTALE. **We are not badly misconfigured** (our export
options are clean), but NFS-exporting a FUSE union to a VM that holds files open *is* a known anti-pattern.
It's **mitigable, not eliminable**, short of changing storage topology (which our capacity forbids — see
below).

## The incident (2026-06-26)

qBittorrent (in the `qbt` microVM, whose `/downloads` is a **virtiofs re-share of the NFS-backed**
`/media/data/Media/Temp`) failed with `file_open: Stale file handle` and errored the torrent. Pausing/
resuming in the WebUI didn't help — virtiofsd still held the dead handle. While switching `/media/data`
from `x-systemd.automount` to a static mount, the servarr console **scrolled
`NFS: server 192.168.1.2 error: fileid changed`** and the unmount hung — the same instability, surfaced
hard by unmounting a busy NFS mount with stale fileids. Disk space was never involved (2.3 TB free).

## Root cause (confirmed against our box + multiple sources)

1. **fileid == inode number.** An NFS file handle encodes the inode; the kernel logs `fileid changed`
   and invalidates the handle when the inode behind a path changes (Trond Myklebust, linux-nfs; Red Hat
   ESTALE solution 2674).
2. **shfs synthesizes unstable inodes.** `/mnt/user` and `/mnt/user0` are `fuse.shfs` — Unraid's union
   over the array disks. shfs does **not** pass through the underlying disk inode reliably; it can
   reassign a synthetic inode for the same path. Same failure family as `mergerfs` (its maintainer:
   *"NFS just isn't a good choice for a unionfs / FUSE in general… you must not change things out of
   band"*).
3. **The `fuse_remember` timer is the trigger.** shfs is mounted `-o remember=N` (default **330 s**).
   After N seconds of inactivity on a cached file/dir name, shfs may forget it and re-synthesize a
   different inode on next access → fileid change → ESTALE.
4. **Compounded on our box:** the `data` share is **spread across disk1 + disk2** (a true multi-disk
   union — *not* ZFS; the only ZFS pool, `cache`, isn't involved), so merged-namespace inodes are even
   less stable. And we negotiate **NFSv4.1/4.2** (v4.0 disabled), which does strict change-attribute
   checking — it *loudly* reports the mismatch where NFSv3 would silently follow a stale handle.

## Our actual config (as of 2026-06-26)

- **Storage:** tower (Unraid **7.3.1**), kernel `nfsd` (v3/4.1/4.2 on, 4.0 off). `data` = ~**12.4 TB**
  across **disk1 (7.3 TB, 88 % full)** + **disk2 (7.3 TB, 83 % full)**. ZFS `cache` pool = 450 GB.
  Tower RAM 30 GB, **no swap**, ~4.5 GB available.
- **Export (`/etc/exports`) — clean:** `fsid=101`, `no_subtree_check`, `all_squash` →
  `anonuid=99,anongid=100`, per-subnet host rules. Unique fsid, correct subtree handling — nothing to fix
  here.
- **Tunables (`/boot/config/share.cfg`):** `shareNFSEnabled=yes`, `fuse_useino=yes`,
  `fuse_remember` (was **330**; now **604800** — see below). Per-share `data.cfg`: `shareUseCache=no`,
  `shareExportNFSFsid=101`, `shareSecurityNFS=private`.

## What we changed / mitigations (layered — none is a complete fix on its own)

**Client side (in this Nix repo):**
- **Static `hard,softreval` mount, never `x-systemd.automount`.** `servarr`'s `/media/data` now uses the
  shared server module `homelab.mounts.nfsLocal` (the same one doc2 uses). Automount lazily remounts and
  strands held handles; static + `hard` (block-and-resume across a blip) + `softreval` (serve cached
  attrs during brief revalidation) is the server pattern. Primary-source-backed: `fileid changed` is
  *"more likely on partitions unmounted/remounted often… exclusively with the automounter."* See
  [services/servarr-and-qbt-cage.md](../services/servarr-and-qbt-cage.md) (the "host NFS mount MUST be
  static" gotcha).
- **`homelab.nfsWatchdog`** stat-probes `/media/data/Media/Temp` and restarts `microvm@qbt.service` (so
  virtiofsd re-opens fresh handles) + raises a Loki alert if it ever does go stale.

**Server side (Unraid flash — NOT in this repo):**
- **`fuse_remember` raised 330 → 604800 (1 week)**, set **2026-06-26** via
  `emcmd "changeShare=Apply&shareNFSEnabled=yes&fuse_remember=604800"` (the CLI equivalent of the GUI
  NFS-settings Apply — writes `share.cfg` *and* emhttp's runtime `var.ini` atomically, so a later GUI
  Apply can't clobber it back). Backup at `/boot/config/share.cfg.bak-fuse-remember`.
  - **Why a large *bounded* value and not `-1` ("forever"):** tower has **no swap** and ~4.5 GB free;
    `-1` grows the cache unbounded (~108 bytes per file/dir name ever accessed via NFS). A week is
    effectively "forever" for our always-seeding workload but keeps the cache self-pruning. We also
    already have the two client-side backstops above, so we don't need `-1` (which the Unraid helptext
    lists as the escalation *"if no other timeout seems to solve it"*). **`-1` is the escalation** if
    ESTALE recurs after this is active.
  - **⚠️ ACTIVATION PENDING:** `remember=N` is a `shfs` mount argument baked at array start, so the
    running shfs still uses `remember=330` until **the array is Stopped→Started, or tower reboots**
    (either re-reads `share.cfg`). We did **not** force an array restart (it bounces Plex, all VMs incl.
    servarr, and every Docker container) — it'll take effect on the next natural reboot. Verify after:
    `ps -C shfs -o args=` on tower should show `-o remember=604800`.

## The real fix DOES work for a small subset — magazines (2026-06-28)

The "not viable" caveat below is about the **whole 12.4 TB media library**. For a *small* dataset the
single-disk real fix is not only viable, it's the right call — and we applied it to the **wine-magazine
archive** (2.6 GB):

- A dedicated Unraid user share `magazines` pinned to a **single array disk** (`shareInclude="disk1"`,
  `shareUseCache="no"`) → one XFS backing disk, so shfs has nothing to reassign inodes across → ESTALE
  class gone for this tree.
- Exported as its **own** NFS share `192.168.1.2:/mnt/user/magazines`, `private`, scoped to exactly
  doc2 `192.168.1.35` (rw), epi `192.168.1.5` (rw), framework `100.78.17.73` (**ro**, defense-in-depth).
- Mounted at `/mnt/magazines` (NixOS module `modules/nixos/services/mounts/magazines-nfs.nix`,
  `homelab.mounts.magazines`), fully decoupled from the `/mnt/data` union. Consumers (gwm-archiver,
  komga, komga-sync, marker-convert) repointed; added to kopia-mum + kopia-photos for backup.

**Why this was the trigger:** gwm-archiver runs with `ProtectSystem=strict` + `ReadWritePaths=[GAW]`. The
write-churned `GAW/` leaf on the multi-disk union flapped its NFS filehandle, so systemd's namespace
setup resolved a stale handle → `status=226/NAMESPACE` (it failed *before* the script even ran). Binding
the mount root RO (the podcast trick) doesn't help a *writer*; moving to a stable-inode share does. The
takeaway: **small, ESTALE-sensitive datasets (especially `ProtectSystem=strict` writers) belong on a
single-disk dedicated share, not the `/mnt/user` union.**

## What we did NOT do, and why

- **Export a single disk / ZFS dataset for the WHOLE library (the real fix).** Real filesystems have
  stable inodes → ESTALE class gone. **Not viable on current hardware:** the library is ~12.4 TB and the
  largest single disk is 7.3 TB (and both are 83–88 % full); the `cache` ZFS pool is only 450 GB.
  Consolidating onto one real fs needs a **≥14 TB disk** first. This is the fundamental Unraid tension:
  you can't have multi-disk array capacity *and* stable union inodes. (The magazines carve-out above
  works precisely because 2.6 GB fits on one existing disk.)
- **virtiofs straight from tower → servarr (bypass NFS).** servarr *is* a KVM VM on tower, so this is
  architecturally possible and would drop the strict-NFSv4 fileid layer — but virtiofs-over-shfs inode
  stability is **unproven** (virtiofs of a *real* fs is solid; over the shfs union, uncertain), and it's
  a non-trivial re-architecture (libvirt virtiofs config lives on the Unraid flash, not Nix). Parked as a
  possible future improvement.

## Latent hardlink caveat (documented, NOT being chased — decision 2026-06-26)

The same multi-disk union breaks `*arr` hardlink imports: hardlinks **cannot cross disks**, and shfs
doesn't support hardlinks across the union. When a completed download in `Media/Temp` lands on disk1 but
the import target ends up on disk2, the *arr silently **copies** instead of hardlinking → that torrent
eats **2× space** (seed copy + library copy) instead of sharing one inode. On disk1 at 88 % full this is
a real cost. We are **not** addressing it now (explicit user call). If revisited: smoke-test with
`ln <file-on-mount> <newlink>` + `stat -c %h` through a real import to measure the hardlink hit rate; the
realistic fixes are a bigger consolidation disk or staging downloads + active seeds on the `cache` pool
(real inodes) with cold archive on the array.

## `fuse_remember` reference

- **Unit:** seconds the shfs FUSE layer caches a file/dir name. **Default 330** (5½ min).
- **Special values (from tower's own `helptext.txt`):** `0` = **don't cache at all** — appropriate ONLY
  if you export *disk* shares, never user shares; on a user share `0` **maximises** stale handles. `-1` =
  **cache forever** (until array stop), ~**108 bytes per cached name** RAM cost.
- **Where it lives:** `/boot/config/share.cfg` (`fuse_remember="…"`), mirrored to emhttp `var.ini`. The
  shfs mount uses it as `-o remember=N` (`ps -C shfs -o args=`).
- **To change (without a disruptive thread/protocol reload):**
  `emcmd "changeShare=Apply&shareNFSEnabled=yes&fuse_remember=<N>"` after backing up `share.cfg`. Takes
  effect at the next **array Start / reboot** (shfs remount) — there is no live reload of a FUSE mount's
  remember window.

## When to revisit

- **After the next tower reboot:** confirm `shfs … -o remember=604800` is live; watch for any recurrence
  of `fileid changed` / ESTALE on `{host="servarr"}` (Loki) or the `nfs-watchdog` alert. If it still
  recurs, escalate `fuse_remember` to `-1` (accept the RAM cost; tower has headroom for a media-sized
  file count).
- If we ever get a **≥14 TB disk** or move the library to a real fs/dataset, prefer exporting *that* (or
  virtiofs from tower) and retire the whole shfs-NFS workaround — it fixes ESTALE **and** hardlinks at
  once.

## Sources

- Unraid `fuse_remember` helptext (on-box): `/usr/local/emhttp/languages/en_US/helptext.txt`.
- Unraid forum: "NFS error: fileid changed", "NFS is about useless in 6.8.0", "Working with NFS on
  Unraid – Best Practices" (2026); shfs non-stable inodes feature requests.
- mergerfs (FUSE-union analog): trapexit, discussion #1304 + Kernel-Issues wiki; diymediaserver
  "fix stale NFS file handles".
- Kernel/NFS: linux-nfs (Trond Myklebust, fileid==inode, automount aggravates); Red Hat ESTALE
  solution 2674; `nfs(5)` man page (mount option semantics).
