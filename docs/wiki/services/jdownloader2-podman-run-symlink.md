# JDownloader2 — podman `/run` symlink incompatibility (jlesage v26.07.1)

- **Date:** 2026-07-09
- **Status:** worked around (runtime), waiting on upstream to restore a real `/run`
- **Host/service:** doc2 · `modules/nixos/services/jdownloader2.nix` · `download.ablz.au`
- **Origin:** overnight RCA→PR pipeline opened Forgejo PR #27; the PR fix was
  necessary but incomplete (see below).

## Symptom

`download.ablz.au` returned **HTTP 502**; `podman-jdownloader2.service`
crash-looped. Two distinct failures depending on config:

1. No `/run` fix → crun aborts before the entrypoint:
   `crun: creating '/run/.containerenv': openat2 'run': No such file or directory`.
2. With `--tmpfs=/run` → gets past crun but dies in cont-init:
   `08-clear-tmp-dir.sh: rm: can't remove '/tmp/run/.containerenv': Resource busy`.

## Root cause

The 06:00 auto-update pulled `jlesage/jdownloader-2:latest` **v26.07.1**. In that
image `/run` is a **symlink to `/tmp/run`**, and **`/tmp/run` does not exist** in
the rootfs (`/tmp` is empty). Under podman this breaks two ways:

1. **crun `.containerenv`.** podman/crun writes `/run/.containerenv` *before* the
   entrypoint runs. It resolves through the dangling symlink to
   `/tmp/run/.containerenv` → parent missing → ENOENT. (Docker never creates
   `.containerenv`, so the image is fine on Docker — this is podman-only.)
2. **clear-tmp EBUSY.** `--tmpfs=/run` fixes (1) because the mount follows the
   symlink and materialises `/tmp/run`. But that makes `/tmp/run` a *mountpoint*,
   and podman bind-mounts `.containerenv` as a *file* under it. The stock init
   script `/etc/cont-init.d/08-clear-tmp-dir.sh` then does `rm -rf /tmp/run`
   (or, in its "secrets" branch, `find /tmp/run … -exec rm -rf`), which hits the
   busy `.containerenv` mount → EBUSY → `set -e` → cont-init aborts → crash-loop.

The busy `.containerenv` is unavoidable via mount tricks: it always lands under
`/tmp/run`, and any path that lets the stock script touch it fails. Tested and
ruled out: `--tmpfs=/run/secrets` (still takes the `rm -rf /tmp/run` branch).

## Fix (runtime, no image pin)

Both are needed, in `jdownloader2.nix`:

1. `--tmpfs=/run:rw,nosuid,nodev,exec,size=64m` — materialise `/run` for crun.
2. Bind-mount a **no-op** over the broken init script:
   `"${clearTmpNoop}:/etc/cont-init.d/08-clear-tmp-dir.sh:ro"` where `clearTmpNoop`
   is a `pkgs.writeTextFile` `#!/bin/sh … exit 0`. `/tmp` is a fresh overlay on
   every container (re)creation, so skipping the clear is safe.

Image pinning is a hard no (autoupdate everywhere), and we don't rebuild the
image — neutralising the one broken script is the least-invasive runtime fix.

Verified end-to-end on doc2 2026-07-09: `podman run` with the real cap set +
`NET_BIND_SERVICE`, cont-init completes, nginx listens, `HTTP 200` on the UI.

## When to revisit / retire

When a newer image restores a real `/run` (or ships an existing `/tmp/run`), the
no-op override becomes inert but harmless. Periodically test removing the
override; if cont-init still passes and the UI serves, drop both the override and
this note. Track upstream: `github.com/jlesage/docker-jdownloader-2`.

## Gotcha for the RCA pipeline

The overnight RCA (PR #27) correctly identified failure (1) and added
`--tmpfs=/run`, but couldn't see failure (2) — it only surfaces *after* the tmpfs
lets the container reach cont-init. Morning triage caught it by re-probing live
after deploy and reading the container journal, not by trusting the PR diff.
Lesson encoded in the `triage-overnight` skill's Step 1c review checklist
("is the service still down?" — re-probe after merge+deploy, don't assume green).
