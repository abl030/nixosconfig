# wsl on-demand `/mnt/data` + Cullen NFS/Syncthing hardening

- **Researched/built:** 2026-07-01
- **Status:** ✅ live on wsl (deployed + verified end-to-end)
- **Issue:** forgejo#4 (Harden + clarify the Cullen-site NFS + Syncthing mounts
  under `tag:cullen` isolation), part of #239 (tailscale least-privilege ACL)
- **Code:** `hosts/wsl/data-mounts.nix`, `modules/nixos/services/mounts/ops-sync.nix`,
  `hosts.nix` (wsl entry), `tailscale/acl.hujson`

## Threat model

wsl is the fleet's presence at the Cullen site and the **least-trusted** box.
Concern: commodity ransomware on the Cullen box (or Windows host) that, overnight,
crawls and encrypts everything currently mounted. wsl mounts the **home NAS**
(`tower:/mnt/user/data`), and the tower `data` share is **not on ZFS**, so there
is **no fast server-side rollback** — the offsite kopia backups are the only
recovery path. So the goal is to minimise what is mounted, and when.

## What was wrong

`/mnt/data` came from the shared `modules/nixos/services/mounts/nfs.nix`, which
mounts the **whole** share RW via `x-systemd.automount`. Automount means *any*
filesystem access (an indexer, `find /`, a ransomware crawler) silently mounts
it, and the 5-min idle-timeout never fires while an encryptor keeps touching it —
so the idle-timeout is cosmetic against an active encryptor. Worse, the nightly
`ops-sync` job **auto-mounted the whole share RW every night** to write a small
Cullen backup — i.e. the entire NAS was writable during exactly the overnight
window of concern.

## The design (three parts)

1. **Human access → on-demand, self-unmounting.** `homelab.mounts.nfs.enable =
   false` on wsl. `hosts/wsl/data-mounts.nix` defines a `noauto` mount (no
   automount → nothing can silently trigger it) plus `data-mount` / `data-umount`
   commands. wsl is locked (no passwordless sudo; `nixos` has no password), so the
   commands trigger the mount via a **NOPASSWD sudo rule scoped to exactly
   `systemctl start/stop mnt-data.mount`** — nothing else. An idle reaper unmounts
   after 15 min with no open files (`fuser -sm`); a `data-mount-daily-umount`
   timer force-unmounts at **17:00** (end of workday — the owner wanted the
   "done-for-the-day → asleep" gap closed, not just the small hours). Net: the NAS
   is unmounted and un-triggerable ~23 h/day. This is a **window-limiter**, not a
   blast-radius bound — while you're working with it mounted RW, everything is
   reachable by anything running as you (recovery = offsite kopia).

2. **Automated writer (ops-sync) → narrowed.** ops-sync no longer touches
   `/mnt/data`. It brings up its **own** RW NFS mount of just
   `.../Life/Cullen/Ops Backup` at `/mnt/ops-backup`, for the duration of the sync
   only, torn down by an `EXIT` trap. Done in-script (root service) which also
   sidesteps fstab space-escaping for the `Ops Backup` path. Unattended blast
   radius = one folder.

3. **Syncthing dropped from wsl.** Removing `syncthingDeviceId` from wsl's
   `hosts.nix` entry both stops syncthing on wsl (the module is gated on
   `hostConfig ? syncthingDeviceId`) and drops wsl as a peer from every other mesh
   member (device lists are built from hosts *with* an id). In the ACL, `tag:cullen`
   was removed from the syncthing grant (its only p2p mesh path into the fleet) and
   `22000` moved to the cullen deny test. Syncthing was considered as the NAS
   transport (issue's original idea) and **rejected**: it can't hold a multi-TB
   NAS, and a standing sync mesh is the opposite of Cullen least-reach.

The `tag:cullen` management plane was verified **already complete** (DNS,
fleet-update via doc1 `.29:443`, Loki/Mimir/Gotify via doc2 `.35:443/8050`,
igpu/servarr `:443`, tower NFS `:2049`, doc1 SSH, Hermes webhook), with the
`tests{}` block asserting the isolation denies. Empirically, wsl fleet-updated
successfully over this ACL. No change needed there.

## ⚠️ Gotcha: automount → noauto on a *live* mount fails the switch

Migrating a **currently-mounted** `x-systemd.automount` NFS mount to `noauto` +
`soft` **fails `nixos-rebuild switch` with exit 4** and leaves the mountpoint
broken:

- NFS **cannot remount `hard`→`soft`**, so switch-to-configuration's reload
  (remount) of the changed `mnt-data.mount` errors.
- The aborted switch removes the `.automount` unit but **orphans its bare
  `autofs`** at the mountpoint. Symptom: `mountpoint /mnt/data` = true, but `ls` →
  **"Host is down"**, and `data-mount` sees the autofs as "already mounted" so
  won't mount NFS.
- The scoped `data-umount` removes the NFS layer but **not** the autofs beneath
  it. Clearing the autofs needs a root `umount` or (on WSL) a `wsl --shutdown`
  reboot.

**How to avoid:** do automount→manual conversions with the mount **unmounted
first**, or expect a one-time reboot. This is self-healing going forward here: the
17:00 force-unmount means unattended deploys almost always find `/mnt/data`
already down, so a future option change won't re-trigger it.

## Verification (2026-07-01)

- `/mnt/data` boots unmounted (no autofs); `mnt-data.automount` = `not-found`.
- `data-mount` → `nfs4 … soft,timeo=30,retrans=2`, share lists; `data-umount` →
  clean empty dir. NOPASSWD sudo rule works.
- `data-mount-daily-umount.timer` → 17:00; `data-mount-reaper.timer` → 5-min.
- ops-sync `After=` = `network-online + mnt-z` (no `mnt-data`); deployed script
  JIT-mounts `/mnt/ops-backup`.
- `syncthing.service` = `not-found` on wsl; device dropped from doc1's config;
  ACL pushed to control (`gitops-pusher`: control checksum advanced, cullen out of
  the syncthing grant).

## When to revisit

- If the tower `data` share ever moves to ZFS, add frequent snapshots — that would
  make broad RW from wsl genuinely recoverable (blast-radius bound, not just a
  window-limiter), and this on-demand dance could relax.
- If the endgame FIDO-touch push / further Cullen isolation changes land, re-check
  the `tag:cullen` grants against this doc.
