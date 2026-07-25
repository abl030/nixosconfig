# Nested virtiofs re-export serves sticky ENOENT/ESTALE (slskd move failures)

**Date researched:** 2026-07-25
**Status:** Mechanism reproduced deterministically; production fix not yet applied
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

`hosts/doc2/slskd-microvm.nix` wraps virtiofsd to force `--inode-file-handles=never`
(added 2026-07-19 in `c604cc8f` to stop SQLite handles going stale). Confirmed live:

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

## Fix direction

**Both** modes are unsound when re-exporting FUSE: `never` pins descriptors that die on replacement
(proven above), and `prefer` was already observed to go stale immediately (`c604cc8f`). So the fix is
structural, not a flag:

1. **De-nest slskd's hot paths** — `downloads/` + `incomplete/` on a VM-local virtio-blk disk, or a
   share served **directly** from prom into the slskd guest (single nest, no doc2 middleman). This is
   option 1 in #51 and the only option the evidence actually supports.
2. Stopgap until then: scheduled restart of `microvm-virtiofsd@slskd`.
3. Still worth doing for a definitive upstream-quality trace: **virtiofsd debug logging on the nested
   daemon**. Production fails on its own; one failed LOOKUP with parent inode finishes the RCA. This
   was #51's original "do this first" and has never been done.

## What this is NOT

- **Not a fleet-wide virtiofs indictment.** Single-nest virtiofs on doc1/doc2/igpu is not implicated by
  this incident; the outer daemon was never restarted and never erred.
- **Not the doc1 panic.** That remains unexplained — no stack through fuse/virtiofs was ever captured,
  and doc1 runs `panic_on_oops=0` / `kexec_crash_loaded=0`, so kdump was never armed. Re-run that
  experiment **only** in VM 951, which already has `crashkernel=512M`, `kexec_crash_loaded=1`, a serial
  console and `softlockup_panic=1`.
- **Not the doc2 tty wedge.** Its preserved `doc2-ps.json` shows 64 of 65 D-state tasks in `tty_open`
  and **zero** in any FUSE path. Different problem, TTY layer, still uncaptured — the recovery module
  should collect `sysrq-t` / `/proc/<pid>/stack`, and doc1's `doc2-netconsole.socket` currently receives
  `0B`, so that capture path is non-functional.

## When to revisit

After de-nesting lands: confirm the failure rate stays at 0% under real load for a week, then remove the
stopgap restart timer. If failures recur *after* de-nesting, the mechanism above is wrong and the outer
layer needs re-examination.
