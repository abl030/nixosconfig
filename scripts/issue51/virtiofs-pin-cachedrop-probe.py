#!/usr/bin/env python3
"""nixosconfig#51 - O_PATH staleness probe for the nested virtiofs seam.

Hypothesis under test
---------------------
doc2's re-exporting virtiofsd runs `--inode-file-handles=never`, which makes it
hold ONE O_PATH descriptor per inode the nested guest references
(docs/wiki/infrastructure/virtiofsd-fd-exhaustion.md, #267).  Those descriptors
point into /mnt/virtio, which is itself a FUSE (virtiofs) mount.  A pinned
descriptor into a FUSE filesystem is only as durable as the OUTER server's inode
identity.  If the outer layer re-resolves or invalidates that inode, the pinned
fd refers to something the outer layer no longer maps, and every subsequent
`openat(pinned_fd, name)` fails -- sticky, per-directory, until the daemon
restarts.

This probe emulates the re-exporting daemon WITHOUT a nested VM: it pins an
O_PATH dirfd exactly as virtiofsd does, provokes outer-layer inode churn, then
retries path resolution through the pin.

A clean run proves pinned dirfds survive outer churn (hypothesis WRONG).
Any ESTALE/ENOENT through the pin, while the same path resolves fine by name,
is the production failure signature reproduced (hypothesis RIGHT).

Safety: touches only --root, which must NOT be /mnt/virtio.  Read-mostly; the
only privileged action is drop_caches, which is the documented relief operation
from the wiki above, not a destructive one.
"""
import argparse
import errno
import json
import os
import sys
import time

def emit(log, kind, **kw):
    rec = {"ts": round(time.time(), 3), "kind": kind, **kw}
    line = json.dumps(rec, sort_keys=True)
    print(line, flush=True)
    if log:
        with open(log, "a") as fh:
            fh.write(line + "\n")

def drop_caches(level=2):
    """Collapse the dentry/inode cache -- the wiki's proof operation.

    This is what makes the OUTER virtiofsd release its per-inode O_PATH fds and
    forces re-resolution, which is precisely the event our pinned fd must survive.
    """
    try:
        os.sync()
        with open("/proc/sys/vm/drop_caches", "w") as fh:
            fh.write(f"{level}\n")
        return None
    except OSError as exc:
        return str(exc)

def try_through_pin(dirfd, name):
    """Resolve `name` relative to the pinned O_PATH dirfd (the virtiofsd path)."""
    try:
        fd = os.open(name, os.O_RDONLY, dir_fd=dirfd)
    except OSError as exc:
        return exc
    try:
        os.fstat(fd)
    finally:
        os.close(fd)
    return None

def try_by_name(path):
    """Resolve the same file by full pathname (the control)."""
    try:
        with open(path, "rb") as fh:
            fh.read(1)
    except OSError as exc:
        return exc
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True,
                    help="scratch dir on the virtiofs mount under test")
    ap.add_argument("--log", default=None)
    ap.add_argument("--rounds", type=int, default=20)
    ap.add_argument("--dirs", type=int, default=40,
                    help="how many pinned dirs to hold (emulates inode table)")
    ap.add_argument("--settle", type=float, default=1.0)
    ap.add_argument("--no-drop-caches", action="store_true")
    args = ap.parse_args()

    if os.path.realpath(args.root).startswith("/mnt/virtio/"):
        sys.exit("REFUSING: --root is under /mnt/virtio (production share)")

    os.makedirs(args.root, exist_ok=True)
    emit(args.log, "start", root=args.root, rounds=args.rounds, dirs=args.dirs,
         drop_caches=not args.no_drop_caches)

    # Phase 1: create the tree and PIN an O_PATH dirfd per directory, exactly as
    # virtiofsd does for every inode the nested guest has looked up.
    pins = []
    for i in range(args.dirs):
        d = os.path.join(args.root, f"album-{i:03d}")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "track.bin"), "wb") as fh:
            fh.write(b"x" * 4096)
        pins.append((d, os.open(d, os.O_PATH)))
    emit(args.log, "pinned", count=len(pins))

    stale = enoent = other = 0
    for rnd in range(1, args.rounds + 1):
        churn_err = None
        if not args.no_drop_caches:
            churn_err = drop_caches(2)
            if churn_err:
                emit(args.log, "churn_failed", err=churn_err)
        time.sleep(args.settle)

        round_bad = 0
        for d, dirfd in pins:
            exc = try_through_pin(dirfd, "track.bin")
            if exc is None:
                continue
            ctrl = try_by_name(os.path.join(d, "track.bin"))
            kind = ("PIN_STALE_NAME_OK" if ctrl is None
                    else "BOTH_FAILED")
            if exc.errno == errno.ESTALE:
                stale += 1
            elif exc.errno == errno.ENOENT:
                enoent += 1
            else:
                other += 1
            round_bad += 1
            emit(args.log, kind, round=rnd, dir=d,
                 pin_errno=exc.errno, pin_err=exc.strerror,
                 ctrl_errno=(ctrl.errno if ctrl else None))
        emit(args.log, "round", round=rnd, failures=round_bad)

    emit(args.log, "summary", estale=stale, enoent=enoent, other=other,
         verdict=("REPRODUCED" if (stale or enoent or other) else "CLEAN"))

    for _, dirfd in pins:
        os.close(dirfd)

if __name__ == "__main__":
    main()
