#!/usr/bin/env python3
"""nixosconfig#51 E4 harness -- runs INSIDE the nested guest.

Round 1 of this experiment showed that an external writer replacing a directory
does NOT break the guest: virtiofsd's cache=auto entry expires, it re-LOOKUPs,
and it picks up the new inode. Re-opening by full path every time hides the bug.

That is not slskd's profile. slskd created its destination directory at 13:37 and
was still trying to move files into it at 16:56 -- it held a reference the whole
time. A held reference keeps the guest's FUSE lookup count above zero, so
virtiofsd never forgets the inode and keeps using its pinned O_PATH descriptor
instead of re-resolving.

So this round holds the directory open, the way slskd did, and then exercises the
operations slskd actually performed against it:

  A  openat(held_dirfd, "track.bin")          -- read through the held reference
  B  open("<full path>/track.bin")            -- fresh lookup, the control
  C  create a new file via the held dirfd     -- what a download does
  D  rename a file INTO the directory         -- the exact failing operation

Handshake goes through /data/_sync (written before any churn, so it is not itself
under test). All output is JSON on the console, captured on VM951.
"""
import errno
import json
import os
import time

DATA = "/data"
SYNC = os.path.join(DATA, "_sync")
N = 12


def emit(kind, **kw):
    print("L2H " + json.dumps({"t": round(time.time(), 2), "kind": kind, **kw},
                              sort_keys=True), flush=True)


def code(exc):
    return errno.errorcode.get(exc.errno, str(exc.errno)) if exc else "OK"


def attempt(fn):
    try:
        fn()
        return None
    except OSError as exc:
        return exc


def wait_for(path, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.5)
    return False


def main():
    for _ in range(60):
        if os.path.isdir(DATA):
            break
        time.sleep(1)
    os.makedirs(SYNC, exist_ok=True)
    emit("start", data=DATA, albums=N)

    # Create the albums and HOLD an open descriptor on each directory, which is
    # what keeps virtiofsd's pinned O_PATH fd alive on the host side.
    held = []
    for i in range(N):
        d = os.path.join(DATA, f"album-{i:03d}")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "track.bin"), "wb") as fh:
            fh.write(b"x" * 65536)
        # A source file to rename in later, kept outside the album dir.
        src = os.path.join(DATA, f"pending-{i:03d}.bin")
        with open(src, "wb") as fh:
            fh.write(b"y" * 4096)
        held.append((i, d, os.open(d, os.O_RDONLY | os.O_DIRECTORY), src))
    emit("held_open", count=len(held))

    open(os.path.join(SYNC, "READY"), "w").close()
    emit("waiting_for_external_churn")
    if not wait_for(os.path.join(SYNC, "CHURNED"), 600):
        emit("timeout_no_churn")
        return
    time.sleep(2)

    results = {}
    for i, d, dfd, src in held:
        replaced = (i % 2 == 0)
        a = attempt(lambda: os.close(os.open("track.bin", os.O_RDONLY, dir_fd=dfd)))
        b = attempt(lambda: os.close(os.open(os.path.join(d, "track.bin"), os.O_RDONLY)))
        c = attempt(lambda: os.close(
            os.open("created-via-held.bin", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd)))
        e = attempt(lambda: os.rename(src, os.path.join(d, "moved.bin")))
        row = {"replaced": replaced, "A_read_held": code(a), "B_read_path": code(b),
               "C_create_held": code(c), "D_rename_into": code(e)}
        results[os.path.basename(d)] = row
        if any(v != "OK" for k, v in row.items() if k != "replaced"):
            emit("FAILURE", dir=os.path.basename(d), **row)

    replaced_rows = [r for r in results.values() if r["replaced"]]
    control_rows = [r for r in results.values() if not r["replaced"]]

    def summarise(rows, key):
        return sorted({r[key] for r in rows})

    keys = ("A_read_held", "B_read_path", "C_create_held", "D_rename_into")
    emit("summary",
         replaced={k: summarise(replaced_rows, k) for k in keys},
         controls={k: summarise(control_rows, k) for k in keys})

    # Stay alive so the stack can be inspected while the fault (if any) is live.
    while True:
        time.sleep(30)
        still = {}
        for i, d, dfd, src in held:
            exc = attempt(lambda: os.close(os.open("track.bin", os.O_RDONLY, dir_fd=dfd)))
            still[os.path.basename(d)] = code(exc)
        emit("persistence_check", states=sorted(set(still.values())),
             failing=sum(1 for v in still.values() if v != "OK"))


if __name__ == "__main__":
    main()
