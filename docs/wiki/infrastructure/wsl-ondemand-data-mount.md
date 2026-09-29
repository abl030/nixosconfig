# wsl on-demand `/mnt/data` + Cullen NFS/Syncthing hardening

- **Researched/built:** 2026-07-01
- **Status:** ✅ live on wsl (deployed + verified end-to-end)
- **Issue:** forgejo#4 (Harden + clarify the Cullen-site NFS + Syncthing mounts
  under `tag:cullen` isolation), part of #239 (tailscale least-privilege ACL)
- **Code:** `hosts/wsl/data-mounts.nix`, `modules/nixos/services/mounts/ops-sync.nix`,
  `secrets/hosts/wsl/ops-sync-cifs.cred`,
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

## ops-sync source: rclone over SMB (2026-09-29)

- **Status:** ✅ live on wsl; verified with a full manual run on 2026-09-29.
- **Symptom:** nightly Gotify "ops-sync skipped on wsl: Source /mnt/z/Operations
  & Production/ not available after 5 attempts" from 2026-09-16 on. The last
  good syncs were 09-21/22, when WSL had been restarted from the desktop.
- **Root cause (verified 2026-09-29):** Windows starts the WSL VM at boot through
  the `Start-NixOS-WSL` scheduled task, which uses an **S4U** logon (a batch
  logon with no password). The VM's interop and drvfs therefore run in a logon
  session that cannot use the saved Credential Manager login for
  `192.168.100.201`. From that context, `net use Z: \\192.168.100.201\Data`
  returns "The password or user name is invalid", then error 1223, so drvfs
  reports `special device Z: does not exist`. Mapping Z: by hand in Explorer
  cannot help, because that mapping lives in the desktop logon session, not the
  VM's. The old reconnect preflight also ran `net use Z: /delete`, which wiped
  the remembered mapping from `HKCU\Network`.
- **Kernel CIFS does not work either:** commit `333dd607` (branch
  `fix/ops-sync-cifs`, never merged until 2026-09-29) mounted the share with
  `mount -t cifs`. On the WSL kernel `6.6.87.2-microsoft-standard-WSL2`, every
  variant fails with `sign fail cmd 0x3` / `SMB signature verification returned
  error = -13` / `failed to connect to IPC`. The variants tried were no domain,
  `domain=CULLENWINES` or `WORKGROUP`, `vers=2.1`/`3.0`, `nodfs`, `seal`, and
  `sec=ntlmssp[i]`. The credential is valid: userspace `smbclient` lists the
  folder with it, while a wrong password gets `NT_STATUS_LOGON_FAILURE` (no guest
  fallback). The kernel has `cmac(aes)` and `gcm(aes)`.
- **Fix:** ops-sync runs `rclone sync` from the on-the-fly remote
  `:smb:Data/Operations & Production` (host `192.168.100.201`) to the narrow NFS
  mount `/mnt/ops-backup`. There is no source mount at all. The login is read
  from the secret into `RCLONE_SMB_USER` and `RCLONE_SMB_PASS`; the password goes
  through `rclone obscure -` on stdin, never argv, with `RCLONE_CONFIG=/dev/null`.
  The previous rsync excludes are kept (`Thumbs.db`, `.stfolder/**`,
  `desktop.ini`, `~$*`), and excluded files on the destination are not deleted.
  `wslOpsSyncSourceCheck` fails if the script regresses to `/mnt/z` or
  `mount -t cifs`.
- **Credential:** `secrets/hosts/wsl/ops-sync-cifs.cred` is a sops binary with
  `username=`/`password=` lines (the filename predates rclone). It decrypts to
  `/run/secrets/ops-sync/smb-credentials` (root, 0400), and only wsl plus the
  editor and break-glass keys can decrypt it. **It is the file server's
  `administrator` account, by the owner's explicit choice (reconfirmed
  2026-09-29).** A root compromise of wsl therefore yields admin on the Cullen
  file server. A dedicated read-only SMB account (e.g. `svc-opsbackup`, read on
  this folder only, non-expiring) would bound that; revisit if wsl's exposure
  changes.
- **Rotation:** re-encrypt from inside `secrets/` with
  `sops -e --input-type binary --output-type binary --filename-override hosts/wsl/ops-sync-cifs.cred <plain> > hosts/wsl/ops-sync-cifs.cred`,
  then shred the plaintext.
- **Alternative not taken:** giving the `Start-NixOS-WSL` task a stored password
  (logon type Password) would give the VM network credentials, so Z: could work
  again. That stores the Windows password in Task Scheduler and keeps the job
  dependent on Windows drive mappings.

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
- ops-sync `After=` = `network-online` (was `+ mnt-z` until 2026-09-29; no `mnt-data`); deployed script
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
