---
name: wsl-ondemand-data-mount
description: "wsl /mnt/data is on-demand (data-mount/umount), NOT automount; 17:00 force-off; wsl out of syncthing; the automount→noauto live-transition gotcha"
metadata:
  type: project
---

forgejo#4 (Cullen-site NFS/Syncthing hardening under tag:cullen isolation),
landed 2026-07-01. Threat model: ransomware on the least-trusted Cullen box
auto-encrypting everything mounted overnight.

**wsl /mnt/data is now ON-DEMAND, not automount.** `homelab.mounts.nfs.enable =
false` on wsl; the mount + tooling live in `hosts/wsl/data-mounts.nix`:
- `data-mount` / `data-umount` — the whole tower share (RW, `soft`) at `/mnt/data`.
  wsl is locked (no passwordless sudo, `nixos` has no password), so these trigger
  via a NOPASSWD sudo rule scoped to EXACTLY `systemctl start/stop mnt-data.mount`.
- Idle reaper unmounts after 15 min of no open files; `data-mount-daily-umount`
  force-unmounts at **17:00** (owner wanted the end-of-workday gap closed, not 02:00).
- ops-sync (`modules/nixos/services/mounts/ops-sync.nix`) no longer touches
  `/mnt/data`; it JIT-mounts ONLY `.../Life/Cullen/Ops Backup` at `/mnt/ops-backup`
  for the sync (EXIT-trap teardown). Unattended writer blast radius = one folder.
- **wsl is OUT of Syncthing** (dropped `syncthingDeviceId` from hosts.nix → stops
  syncthing on wsl AND drops it as a peer everywhere). ACL: tag:cullen removed from
  the syncthing grant (its only p2p mesh path into the fleet), 22000 moved to the
  cullen deny test. tag:cullen mgmt-plane was already complete (fleet-update/logs/
  Gotify/atuin reachable) — see [[tailscale-acl-state]].

**GOTCHA — migrating a LIVE `x-systemd.automount` NFS mount to `noauto`+`soft`
fails the nixos switch and orphans the autofs.** NFS can't remount `hard`→`soft`,
so switch-to-configuration's reload of the changed mnt-data.mount errors
(`exit 4`); the aborted switch removes the `.automount` unit but leaves its bare
`autofs` at the mountpoint. Symptom: `mountpoint /mnt/data` = true but `ls` →
"Host is down", and `data-mount` sees the autofs as "already mounted" so won't
mount NFS. `data-umount` (my scoped sudo) removes the NFS layer but NOT the autofs
underneath — clearing that needs a root `umount` or, on WSL, a `wsl --shutdown`
reboot. **Do future automount→manual conversions with the mount UNMOUNTED first,
or expect a one-time reboot.** Self-heal here: the 17:00 force-unmount means
unattended deploys almost always find /mnt/data already down, so it won't recur.

Full design + gotcha writeup: `docs/wiki/infrastructure/wsl-ondemand-data-mount.md`.
Related: [[servarr-nfs-static-and-sudo]] (the inverse lesson — automount was the
problem there too).
