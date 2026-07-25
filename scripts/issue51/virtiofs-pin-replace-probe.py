#!/usr/bin/env python3
"""nixosconfig#51 - arm B: does an external writer replacing a directory
poison a pinned O_PATH dirfd, reproducing slskd's signature?

Production pattern being modelled:
  doc2's re-exporting virtiofsd (--inode-file-handles=never) pins ONE O_PATH
  dirfd per inode the slskd guest looked up.  Meanwhile OTHER writers
  (slskd itself via a different path, beets, cratedigger on doc1) delete and
  recreate directories under the same tree.  A recreated directory is a NEW
  inode; the pinned fd still refers to the OLD, now-unlinked one.

Expected signature if this is the mechanism -- and it is exactly what slskd
reported:
  * openat(pinned_dirfd, "track.bin")  -> ENOENT          (sticky, forever)
  * open("<same path by name>")        -> succeeds        (host "sees" the dir)
  * only the replaced dirs fail; neighbours are fine      (per-album)
  * re-pinning (== restarting the daemon) clears it       (18:47 cure)

Handshake: this runs INSIDE the guest and pins.  The churn is performed by an
EXTERNAL writer (prom, on the backing dataset) so the replacement genuinely
comes from another machine, as in production.
"""
import argparse, errno, json, os, sys, time

def emit(kind, **kw):
    print(json.dumps({"ts": round(time.time(), 3), "kind": kind, **kw}, sort_keys=True), flush=True)

def probe_pin(dirfd, name):
    try:
        fd = os.open(name, os.O_RDONLY, dir_fd=dirfd)
    except OSError as e:
        return e
    os.close(fd); return None

def probe_name(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as e:
        return e
    os.close(fd); return None

def wait_for(path, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.5)
    return False

ap = argparse.ArgumentParser()
ap.add_argument("--root", required=True)
ap.add_argument("--dirs", type=int, default=20)
ap.add_argument("--timeout", type=float, default=180)
a = ap.parse_args()

if os.path.realpath(a.root).startswith("/mnt/virtio/"):
    sys.exit("REFUSING: --root under /mnt/virtio (production share)")

os.makedirs(a.root, exist_ok=True)
sync_dir = os.path.join(a.root, "_sync")
os.makedirs(sync_dir, exist_ok=True)

# Build tree and pin an O_PATH dirfd per album, as virtiofsd does per inode.
pins = []
for i in range(a.dirs):
    d = os.path.join(a.root, f"album-{i:03d}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "track.bin"), "wb") as fh:
        fh.write(b"x" * 4096)
    pins.append((i, d, os.open(d, os.O_PATH)))
emit("pinned", count=len(pins))

# Baseline: every pin must resolve before we churn anything.
base_bad = sum(1 for _, d, fd in pins if probe_pin(fd, "track.bin") is not None)
emit("baseline", failures=base_bad)

open(os.path.join(sync_dir, "READY"), "w").close()
emit("waiting_for_external_churn")
if not wait_for(os.path.join(sync_dir, "CHURNED"), a.timeout):
    emit("timeout_no_churn"); sys.exit(2)
time.sleep(1.0)

# Retest. Even-numbered albums were replaced by the external writer;
# odd-numbered ones were left alone and act as the in-run control.
sticky = clean = ctrl_ok = 0
for i, d, fd in pins:
    pin_err = probe_pin(fd, "track.bin")
    name_err = probe_name(os.path.join(d, "track.bin"))
    replaced = (i % 2 == 0)
    if pin_err is not None and name_err is None:
        sticky += 1
        emit("PIN_DEAD_NAME_OK", dir=os.path.basename(d), replaced=replaced,
             pin_errno=pin_err.errno, pin_err=pin_err.strerror)
    elif pin_err is None and name_err is None:
        clean += 1
        if not replaced: ctrl_ok += 1
    else:
        emit("OTHER", dir=os.path.basename(d), replaced=replaced,
             pin_errno=getattr(pin_err, "errno", None),
             name_errno=getattr(name_err, "errno", None))

# Re-pin == what restarting virtiofsd does. Does it clear the fault?
repin_bad = 0
for i, d, fd in pins:
    try:
        nfd = os.open(d, os.O_PATH)
    except OSError:
        repin_bad += 1; continue
    if probe_pin(nfd, "track.bin") is not None:
        repin_bad += 1
    os.close(nfd)

emit("summary", sticky_pin_failures=sticky, pins_ok=clean,
     untouched_controls_ok=ctrl_ok, after_repin_failures=repin_bad,
     verdict=("REPRODUCED" if sticky else "CLEAN"))
