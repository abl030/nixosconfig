#!/usr/bin/env python3
"""nixosconfig#51 - CONTROL: is the ESTALE behaviour virtiofs-specific?

Same primitive on two filesystems: pin an O_PATH dirfd, replace the directory
by pathname (unlink + recreate == a NEW inode), then resolve through the pin.

A local FS should give ENOENT (fd valid, directory unlinked).  If virtiofs
gives ESTALE instead, the nested re-exporter sees a *different* error class than
it would on real storage -- which matters because virtiofsd's own error mapping
and slskd's .NET layer both react to it.
"""
import errno, json, os, shutil, sys, time

def run(root, label):
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root, exist_ok=True)
    results = []
    for i in range(5):
        d = os.path.join(root, f"album-{i:03d}")
        os.makedirs(d)
        with open(os.path.join(d, "track.bin"), "wb") as fh:
            fh.write(b"x" * 4096)
        pin = os.open(d, os.O_PATH)

        # before
        try:
            fd = os.open("track.bin", os.O_RDONLY, dir_fd=pin); os.close(fd)
            before = "OK"
        except OSError as e:
            before = errno.errorcode.get(e.errno, e.errno)

        # external-style replacement by pathname -> new inode
        shutil.rmtree(d)
        os.makedirs(d)
        with open(os.path.join(d, "track.bin"), "wb") as fh:
            fh.write(b"y" * 4096)

        # after, through the stale pin
        try:
            fd = os.open("track.bin", os.O_RDONLY, dir_fd=pin); os.close(fd)
            after = "OK"
        except OSError as e:
            after = errno.errorcode.get(e.errno, str(e.errno))

        # control: same file by name
        try:
            fd = os.open(os.path.join(d, "track.bin"), os.O_RDONLY); os.close(fd)
            byname = "OK"
        except OSError as e:
            byname = errno.errorcode.get(e.errno, str(e.errno))

        os.close(pin)
        results.append({"before": before, "through_pin": after, "by_name": byname})
    codes = sorted({r["through_pin"] for r in results})
    print(json.dumps({"fs": label, "root": root, "n": len(results),
                      "through_pin_errno": codes,
                      "by_name": sorted({r["by_name"] for r in results})},
                     sort_keys=True), flush=True)
    shutil.rmtree(root, ignore_errors=True)

for label, root in [("virtiofs", "/mnt/virtiofs/ctl-probe"),
                    ("local-ext4", "/var/tmp/ctl-probe")]:
    try:
        run(root, label)
    except Exception as exc:
        print(json.dumps({"fs": label, "error": repr(exc)}), flush=True)
