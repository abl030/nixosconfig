# tower NFS exports — inventory, scoping, and the Unraid generation gotcha

**Last updated:** 2026-08-21
**Host:** tower (Unraid, `192.168.1.2`)
**Related:** [containers-backup-restore.md](containers-backup-restore.md),
[home-assistant-auto-update.md](../services/home-assistant-auto-update.md),
[kopia.md](../services/kopia.md)

tower is the fleet's bulk storage and exports several shares over NFSv4. Two of
those exports were unscoped (`*`, i.e. any host that can reach tower's NFS) until
2026-08-21. This page records what is exported, who actually consumes it, and how
to change it without the change silently reverting.

## Current exports

| Share | Rule | Consumers |
|---|---|---|
| `VMBackups` | `192.168.1.35` ro, `192.168.1.36` ro, `192.168.1.20` rw | doc2 (kopia-mum walks `containers` + `homeassistant`), HAOS (writes its nightly backups) |
| `data` | `100.0.0.0/8` rw, `192.168.1.29` rw, `192.168.1.0/24` rw | doc1, doc2, servarr, prom (→ igpu CT), framework — the media library |
| `magazines` | `192.168.1.35` rw, `192.168.1.5` rw, `100.78.17.73` ro | doc2 (kopia-mum), epi |
| `domains` | **`*` ro** ⚠️ | **none found** — see below |
| ~~`appdata`~~ | **retired 2026-08-21** | none |

`exportfs -v` is the source of truth for what is live; `/boot/config/shares/<Share>.cfg`
is the source of truth for what survives a reboot.

## ⚠️ `domains` is still world-readable

`/mnt/user/domains` is exported `*(ro,sec=sys,insecure,anongid=100,anonuid=99,all_squash)`
— readable by **any host that can reach tower's NFS**. It holds VM disk images
(e.g. `/mnt/user/domains/PBS/vdisk1.img`).

No NixOS host mounts it: nothing in this repo references `/mnt/user/domains` or
`/mnt/domains`, and doc1's `/mnt/domains` is an empty leftover directory, not a
mount. tower's own libvirt uses the path **locally**, which does not require an
NFS export.

This was noticed while retiring `appdata` and deliberately **not** changed, in case
a non-NixOS consumer (a desktop, a one-off VM) depends on it. It is the obvious next
candidate for scoping or unsharing — a read-only copy of every VM disk image is a
meaningful exposure.

## Retired: `appdata` (2026-08-21)

`/mnt/user/appdata` was a temporary bridge while services moved off tower. It was
exported with an **empty rule**, which `exportfs` warns about
(`No host name given with /mnt/user/appdata, suggest *(...)`) and treats as `*`.

Retirement was safe to do because nothing consumed it:

- no path under `/mnt/appdata/` is referenced anywhere in this repo
- all three live consumers reported **0 open files**

Consumers removed, established by inspection rather than assumption:

| Consumer | How it got the mount | Removal |
|---|---|---|
| doc1 | `homelab.mounts.nfsLocal` (appdata defaulted **true**) | option deleted from the module; deployed |
| doc2 | same | same |
| prom → igpu CT 107 | prom mounted it at `/mnt/tower-appdata` (fstab) and bind-mounted it in as `mp5` | `mp5` removed from `/etc/pve/lxc/107.conf`, host mount + fstab line removed |
| framework | roaming `homelab.mounts.nfs` pattern | option deleted; applies on its next rebuild (roaming box, not deployed from doc1) |
| servarr | already `appdata = false` | dead assignment dropped |

The `appdata` **option itself** was removed from both `mounts/nfs.nix` and
`mounts/nfs-local.nix` rather than merely defaulted off, so it cannot be switched
back on by accident. tower's local Docker use of `/mnt/user/appdata` is unaffected —
unsharing only removes the network export.

### Loose end: igpu still holds the old mount until it restarts

Removing `mp5` from the CT config stops the bind returning on the next start, but it
does **not** unmount it from a running container. igpu had a live Jellyfin transcode,
so it was not restarted.

Unmounting it out of band turned out not to be practical, and the reasons are worth
recording:

- `pct set 107 --delete mp5` on a **running** CT did not persist (the config still
  showed `mp5`). CT 107 also carries a leftover `snapstate: prepare` /
  `snaptime` from an interrupted snapshot, which is a plausible cause. The line was
  removed by editing `/etc/pve/lxc/107.conf` directly.
- `nsenter -t <pid> -m -- umount` fails on a **NixOS** container: `umount` is not on
  the default PATH there (it lives at `/run/wrappers/bin/umount`, a setuid wrapper,
  or `/run/current-system/sw/bin/umount`).
- the setuid wrapper then fails under `nsenter` with
  `cannot get capabilities for /proc/self/exe` unless you also enter the PID namespace.
- even with the raw `util-linux` binary and `-m -p`, and via `pct exec`, umount
  reports `/mnt/appdata: not mounted` while `/proc/<pid>/mounts` still lists it —
  the mount is visible to the container's login sessions but not to the namespace
  `pct exec` lands in.
- igpu is a `locked`-role host with **passworded** sudo, so unmounting from inside
  over SSH is not available either.

**Resolution:** restart CT 107 (`pct reboot 107` on prom) at a moment when nothing is
streaming. The config change is already in place, so the mount will not come back.
Until then igpu has a dead `/mnt/appdata`; nothing reads it, and NFSv4 export removal
returns `ESTALE` rather than hanging a `hard` mount.

## Changing an export without it reverting

**`/etc/exports` on Unraid is generated.** Editing it alone works until the next array
restart or share edit, then the change is lost.

1. Edit the persistent share config: `/boot/config/shares/<Share>.cfg`
   - `shareExportNFS="e"` to export, `"-"` to unshare
   - `shareSecurityNFS="private"` for a scoped rule (`"public"` renders `*`)
   - `shareHostListNFS="ip(opts) ip(opts) …"`
2. Mirror the same rule into `/etc/exports`
3. `exportfs -ra`
4. Verify with `exportfs -v`

Copy the rule syntax from an already-scoped share (`magazines.cfg` is a good model)
rather than inventing it.

**Unraid has no `python3`** — use sed/awk in any script you pipe over SSH.

An unauthorised NFSv4 client is refused with
`mount.nfs4: … reason given by server: No such file or directory`, not a permission
error — the export simply does not exist in that client's pseudo-filesystem view.

## Who reaches tower over NFS, and who does not

Worth knowing before scoping anything, because several paths that look like NFS are not:

- doc1's `containers-backup.service` and `prom-rpool-backup.service` write to
  `VMBackups` over **SSH**, not NFS.
- the PBS VM (`192.168.1.30`, a tower KVM guest) reaches `VMBackups/proxmox` via
  **virtiofs passthrough** (`virsh dumpxml PBS`), not NFS.
- the `servarr` and `logs` directories inside `VMBackups` are written **locally** by
  Unraid-side jobs.
- prom uses **CIFS** for the `data` share (`cifs: Tower` in `/etc/pve/storage.cfg`)
  in addition to its NFS mount.

Live NFSv4 clients can be listed on tower with:

```bash
cat /proc/fs/nfsd/clients/*/info | grep -E 'address|name'
```

That shows the client host but **not which export** it uses (NFSv4 multiplexes a
single port), so pair it with per-host `mount | grep 192.168.1.2:`.
