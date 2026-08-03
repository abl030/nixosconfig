# Nested virtiofs re-export serves sticky ENOENT/ESTALE (slskd move failures)

**Date researched:** 2026-07-25
**Status:** Mechanism reproduced deterministically; production fixed in `439c4406`, soak underway
**Hosts:** doc2 (re-exporter) → slskd microVM. prom's outer layer is NOT implicated.
**Issue:** [#51](https://git.ablz.au/abl030/nixosconfig/issues/51)
**Related:** [virtiofsd-fd-exhaustion.md](virtiofsd-fd-exhaustion.md) (#267 — same `--inode-file-handles`
mechanism, opposite direction), [doc2-kernel-panic-2026-07-22.md](doc2-kernel-panic-2026-07-22.md)

## TL;DR

Re-exporting a virtiofs mount through a second `virtiofsd` is **unsound in both
`--inode-file-handles` modes**. With `never` (what doc2 forces), virtiofsd pins one `O_PATH`
descriptor per inode into a FUSE mount; when any other writer replaces a directory in that tree the
pin goes **ESTALE**, and the daemon then serves sticky per-directory ENOENT/ESTALE for *every file
under it* until the daemon is restarted. This produced a 37–96% failure rate on slskd's
`incomplete/ → downloads/` moves for six days. **De-nest the hot paths**; do not chase a kernel bug
and do not migrate the fleet off virtiofs on the strength of this incident.

## Symptom

In the slskd guest, downloads complete and then fail to move:

```
System.IO.IOException: Failed to move file ...
 ---> System.IO.DirectoryNotFoundException: Could not find a part of the path.
```

Also seen as `Stale file handle` on *create*, and `Cannot allocate memory`. Three errno flavors
(ENOENT / ESTALE / ENOMEM), two syscall paths (create and rename), **one seam**.

Distinctive fingerprint — this is what rules out an application path bug:

- The destination directory **exists on the host the entire time**, created by the app itself.
- Failures are **per-directory and sticky for hours**; neighbouring albums move cleanly.
- Create succeeds, later rename into the same directory fails.
- **A restart of the re-exporting daemon cures it immediately.**

## Root cause

At the time of the incident, `hosts/doc2/slskd-microvm.nix` wrapped virtiofsd to
force `--inode-file-handles=never` for every share (added 2026-07-19 in
`c604cc8f` to stop SQLite handles going stale). Confirmed live before the block
storage cutover:

```
virtiofsd --shared-dir=/mnt/virtio/music/slskd --cache=auto --inode-file-handles=never
```

Per #267, that mode makes virtiofsd **hold one `O_PATH` fd per inode the guest references**. Here
those descriptors point into `/mnt/virtio` — itself a FUSE (virtiofs) mount. A pinned descriptor is
only as durable as the object it refers to: when slskd's own create/delete/recreate cycle, beets, or
cratedigger on doc1 replaces a directory, the recreated directory is a **new inode** and the pin
refers to the old, unlinked one. Every subsequent `openat(pinned_dirfd, name)` — which is exactly how
virtiofsd resolves guest paths — fails, for every file under that directory, until the inode table is
rebuilt by restarting the daemon.

ENOMEM is the same table under allocation pressure. One mechanism accounts for all three flavors.

## Reproduction (deterministic, ~2 seconds, no load, no crash risk)

Scripts: `scripts/issue51/`. They **refuse to run under `/mnt/virtio`** and are meant for an
isolated lab share (VM 951 / `nvmeprom/issue51-virtiofs-lab`).

```sh
# Arm B — external writer replaces directories while the guest holds pinned dirfds
python3 scripts/issue51/virtiofs-pin-replace-probe.py --root /mnt/virtiofs/probe --dirs 20
#   ... then, from the host, rm -rf + recreate the even-numbered album dirs, touch _sync/CHURNED
```

Measured 2026-07-25 in VM 951:

| Arm | Result |
|---|---|
| 10 dirs replaced externally, resolved through the pinned dirfd | **10/10 ESTALE (errno 116)** |
| Same 10 paths resolved *by name* | 10/10 OK — "visibly present on the host" |
| 10 untouched dirs (in-run control) | 10/10 OK — per-directory, neighbours fine |
| Re-pin (== restart the daemon) | **0 failures — fault fully cleared** |

Filesystem control (`virtiofs-pin-fs-control.py`) — the discriminator:

| Filesystem | through pinned dirfd after replacement |
|---|---|
| **virtiofs** | **ESTALE** |
| local ext4 | ENOENT |

Both fail (POSIX: the pinned directory is unlinked), but virtiofs returns a *different error class*.
That is why the guest sees a mix of "could not find a part of the path" and raw "Stale file handle".

`virtiofs-pin-cachedrop-probe.py` is the **negative** control: dropping the guest dentry/inode cache
does **not** poison a pin (the open fd holds a reference). Cache eviction is not the trigger;
**replacement by another writer** is.

## End-to-end confirmation through a real virtiofsd re-export (E4)

The probes above establish the *primitive*. They do not by themselves prove virtiofsd hits it — and
the first attempt to show that it does **failed**, which sharpened the diagnosis:

- **Round 1 (negative, important):** a harness that re-opened files by full path saw **zero**
  failures after an external replacement. virtiofsd runs `--cache=auto`, so its entry expires, it
  re-LOOKUPs, and it picks up the new inode. *Plain external replacement is not sufficient.*
- **Round 2 (positive):** the missing ingredient is a **held reference**. slskd created its
  destination directory at 13:37 and was still writing into it at 16:56 — it held the directory the
  whole time, which keeps the guest's FUSE lookup count above zero, so virtiofsd never forgets the
  inode and keeps using its pinned descriptor instead of re-resolving.

Measured 2026-07-25 in the full nested stack (`scripts/issue51/l2-lab/`), 12 albums, 6 replaced
externally by prom while the nested guest held an open dirfd on each:

| Operation | Replaced (6) | Untouched controls (6) |
|---|---|---|
| read via **held** dirfd | **ESTALE** | OK |
| create via **held** dirfd | **ESTALE** | OK |
| read by path | OK | OK |
| rename by path | OK | OK |

Sticky across every subsequent check (90 s+, never recovered) while the directories remained plainly
present on prom's backing dataset. That is the incident's central paradox reproduced exactly: the
path resolves fine by name, and everything through the retained reference fails permanently.

**The trigger is therefore two-part** — an external writer replacing a directory **and** the guest
holding a reference across it. Either alone is harmless.

## Timeline that anchors it

slskd was jailed into the nested microVM on **2026-07-19** (`a73909c6`); the stale-handle wrapper
landed the same day (`c604cc8f`). `microvm@slskd`'s journal starting Jul 20 is because **the unit is
six days old**, not because retention is short — there is no earlier history to recover.

Failures per *completed download*:

| Day | Completions | Failures | Rate |
|---|---|---|---|
| Jul 21 | 893 | 768 | 86% |
| Jul 22 | 1600 | 946 | 59% |
| Jul 23 | 2628 | 960 | 37% |
| Jul 24 | 2463 | 2372 | 96% |
| Jul 25 (post-restart) | 292+ | **0** | **0%** |

Last failure **18:44:34 Jul 24 — three minutes before the 18:47 `microvm-virtiofsd@slskd` restart.**
prom's outer virtiofsd for doc2 (PID 2605659) ran continuously from Jul 19 **across the cure** and was
never restarted, which exonerates the outer layer for this failure mode.

## How to diagnose a recurrence

```sh
# on doc2 — is the nested daemon the one degrading?
systemctl show -p MainPID --value microvm-virtiofsd@slskd
for p in $(pgrep -f 'virtiofsd.*slskd'); do
  echo "$p: $(sudo ls /proc/$p/fd | wc -l) fds  $(tr '\0' ' ' < /proc/$p/cmdline | grep -o 'inode-file-handles=[a-z]*')"
done

# failure rate normalised against real load
journalctl -u microvm@slskd --since today | grep -c 'Completed, Succeeded'
journalctl -u microvm@slskd --since today | grep -ciE 'could not find a part of the path|stale file handle|cannot allocate memory'
```

Immediate relief (empirically buys 13h+): stop `microvm@slskd`, restart `microvm-virtiofsd@slskd`,
start the guest.

## Production fix

**Both** modes are unsound when re-exporting FUSE: `never` pins descriptors that die on replacement
(proven above), and `prefer` was already observed to go stale immediately (`c604cc8f`). The production
fix is therefore structural, not a global flag flip.

The selected design keeps both isolation boundaries and introduces no storage-network exception:

```text
prom sparse 300 GiB 64K zvol
  -> virtio-SCSI into the existing doc2 VM
    -> ext4 at /srv/slskd-storage
      -> compatibility bind mounts for state and downloads
        -> one virtiofs layer into the slskd microVM
```

State, downloads, and `incomplete/` are block-backed. Their virtiofsd instances retain
`--inode-file-handles=prefer`, which can use stable ext4 file handles. The wrapper rewrites only the
remaining read-only shares backed by outer FUSE to `never`. Existing guest and Cratedigger paths do
not change.

This was preferred over direct prom-to-guest virtiofs because a malicious Internet-facing slskd guest
still attacks a backend contained by doc2 rather than one running on the Proxmox hypervisor. It was
preferred over NFS because the SLSKD_DMZ needs no new route or storage-server capability. A missing
disk leaves doc2 recoverable but keeps the slskd virtiofs service failed closed.

The signed revision reached doc2 on 2026-07-27. The first post-cutover smoke
window recorded zero known ENOENT/ESTALE/ENOMEM move signatures. That short
window is not the acceptance period: retain the restart workaround and hidden
rollback trees until normalized completed-move failures have remained clean for
at least one week (not before 2026-08-03). Runtime evidence is recorded in
[slskd-cage.md](../services/slskd-cage.md#production-cutover-evidence-2026-07-27).

## What this is NOT

- **Not a fleet-wide virtiofs indictment.** Single-nest virtiofs on doc1/doc2/igpu is not implicated by
  this incident; the outer daemon was never restarted and never erred.
- **Not the doc1 panic.** That remains unexplained — no stack through fuse/virtiofs was ever captured.
  At incident time doc1 ran `panic_on_oops=0` / `kexec_crash_loaded=0`; kdump is now armed separately
  under [fleet-crash-capture.md](fleet-crash-capture.md). Re-run the nested-virtiofs experiment **only**
  in VM 951, which already has `crashkernel=512M`, `kexec_crash_loaded=1`, a serial console and
  `softlockup_panic=1`.
- **Not the doc2 tty wedge.** Its preserved `doc2-ps.json` shows 64 of 65 D-state tasks in `tty_open`
  and **zero** in any FUSE path. Different problem, TTY layer, still uncaptured — the recovery module
  only collected WCHAN, which names the layer but never the lock holder. `sysrq-t`/`sysrq-w` and
  `/proc/<pid>/stack` capture has since been added to `doc2-recovery` (driven over QGA, which stayed
  responsive throughout the wedge while SSH was dead).

  Note on netconsole, revised 2026-08-03: a quiet dedicated prom receiver on UDP/6667 is **not** a
  fault. doc2 boots `loglevel=4`, so only KERN_ERR and above reach any console; routine INFO records
  are filtered by design and the fleet's kernels are simply quiet. Verified end-to-end by sending a
  synthetic datagram from doc2 and observing its source-labelled timestamped record on prom. Oops/panic
  output is EMERG/ALERT/CRIT and is carried, as is sysrq output (`__handle_sysrq` raises
  `console_loglevel` for its duration).

## When to revisit

After cutover: confirm the failure rate stays at 0% under real load for a week. If failures recur on the
two block-backed shares, inspect the active per-share virtiofsd arguments first. If they retain
`prefer`, the mechanism above is incomplete and the outer layer needs re-examination.
