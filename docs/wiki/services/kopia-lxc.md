# kopia in its own LXC (CT 111)

**Status:** live
**Date:** 2026-09-11
**Issue:** forgejo#218
**Hosts:** kopia (CT 111 on prom), prom, doc2
**Code:** `hosts/kopia/configuration-lxc.nix`, `modules/nixos/services/kopia.nix`

**2026-09-13 follow-up:** [Post-migration outage RCA](kopia-mum-outages-2026-09-13.md)
found repository contention through the single-threaded bindfs view, unreadable
Music/Ali Cratedigger source entries, and a monitor schema bug that hides repeated
snapshot errors. The migration is live; backup completeness still needs those fixes.

## Why it moved off doc2

On 2026-09-11 doc2 wedged during an automatic kernel-update reboot.
`systemd-shutdown` blocked forever on a stray `kopia` process it could not reap,
which also held `/mnt/virtio` open so the unmount failed. doc2 carries most
services plus the whole LGTM stack **and Gotify**, so kopia taking doc2 down also
silenced the alert path that should have reported it.

Three things this buys:

- **Blast radius.** A wedged kopia wedges kopia. `pct stop 111` is cheap and
  touches nothing else.
- **Reboot independence.** kopia's verify legitimately runs 05:30–12:00 daily
  (2.7 TB of objects over a ~45 Mbit/s offsite link). Any doc2 reboot in that
  window killed it mid-flight.
- **No virtiofs.** Every path is a plain bind from prom.

## Why an LXC and not a VM

The pfSense source is a ZFS tree with 15 child datasets, and the wiki previously
blamed "kernel-level traversal of ZFS child datasets" on Proxmox. That framing is
wrong, and measuring settled it:

| mount type | child dataset contents |
| --- | --- |
| plain bind (`mount -o bind`) | **invisible** |
| recursive bind (`mount --rbind`) | **visible** |

The old virtiofs and NFS failures were submount-crossing, a protocol property,
not a kernel defect. Proxmox's own `mp:` entries use `mount -o bind`
(`PVE/LXC.pm:2060`), so a `mp:` for a ZFS tree silently yields empty children —
that is the 298-byte-snapshot failure mode.

In the end the pfSense tree does not use `rbind` either, because bindfs (below)
flattens the submounts into one namespace anyway.

## The idmap problem, which is the whole story

An unprivileged CT maps container uid 0 → host uid 100000. That single fact
caused every hard problem here.

**The repository.** kopia-mum's repo lives on mum's Synology, owned uid 1000,
with ~92k directories at mode `0700`. Mode `0744` elsewhere is worse than it
looks: `r--` lets you *list* a directory but gives no `x`, so you cannot *enter*
it. Proven by traversing one sub-shard as different uids:

| uid | traverse |
| --- | --- |
| 0 (root) | OK |
| 1000 (owner) | OK |
| 100000 (container root) | **DENIED** |

doc2 qualified because it mounted the share itself and ran as root. The container
is neither owner nor root, so kopia retried each shard ten times, never bound its
port, and logged nothing above debug level. The symptom is a server that sits
`active` forever having printed only its user-accounts notice.

**The fix is bindfs, on prom.** prom already reads the share as root, so it
re-presents the tree with ownership the container can use. Nothing on the NAS and
nothing in the repository is modified:

```
/mnt/mum  /mnt/mum-ct  fuse.bindfs
  force-user=100000,force-group=100000,      # appear as the CT's root
  create-for-user=1000,create-for-group=100, # writes land as the repo owner
  perms=u=rwX,allow_other,nofail,_netdev,
  x-systemd.requires=mnt-mum.mount           # else it mirrors an EMPTY dir
```

The alternative — chmod'ing ~157k directories and their files — would have taken
hours over that link **and** made the entire offsite backup world-readable. It
was rejected on both counts.

**The pfSense replica needed the same treatment.** The first real snapshot
succeeded but reported 377 fatal errors: root-owned `0600` files (ssh host keys,
`entropy`, `.rnd`) that container-root cannot read. `chown` would not survive,
since syncoid receives as root and recreates them. So that tree gets its own
read-only bindfs view at `/nvmeprom/backup/pfsense-ct`.

## Storage layout

Everything is mounted by prom and bind-mounted in, because an unprivileged CT
cannot mount NFS. Backup **sources are all read-only** — kopia never writes to
them — and only the repository is read-write. That is tighter than doc2, which
had magazines rw.

| in the CT | from prom | notes |
| --- | --- | --- |
| `/mnt/data` | `/mnt/tower-data` | tower NFS, **ro** |
| `/mnt/magazines` | `/mnt/tower-magazines` | tower NFS, **ro** |
| `/mnt/backup/vm-backups` | `/mnt/tower-vmbackups` | tower NFS, **ro** |
| `/mnt/mum` | `/mnt/mum-ct` | concurrent **bindfs** over the Synology, rw |
| `/mnt/virtio/Music` | `/mnt/kopia-sources/music` | ownership-translating **bindfs**, ro |
| `/mnt/virtio/ali-cratedigger` | `/mnt/kopia-sources/ali-cratedigger` | ownership-translating **bindfs**, ro |
| `/mnt/virtio/kopia` | `nvmeprom/containers/kopia` | dataDir, owned 100000 |
| `/mnt/backup/pfsense` | `/nvmeprom/backup/pfsense-ct` | **bindfs**, ro |

The in-container paths are deliberately **identical to doc2's**. kopia keys a
source on hostname+username+path, and both instances pin
`overrideHostname="kopia"` / `overrideUsername="root"`, so the existing history,
policies and schedules matched instead of forking. Proof: the reconciler reported
`declared=10 missing=0 orphans=0`, every source "ALREADY registered".

### Maintaining the prom-side views

The authored fstab entries are in
[`hosts/kopia/prom-mounts.fstab`](../../../hosts/kopia/prom-mounts.fstab).
The CT startup dependency is
[`hosts/kopia/prom-container-mounts.conf`](../../../hosts/kopia/prom-container-mounts.conf),
installed as `/etc/systemd/system/pve-container@111.service.d/kopia-mounts.conf`.
Prom is not a NixOS host: these two files require an explicit prom-side install,
in addition to deploying the flake to the CT. Preserve unrelated fstab entries.

Music and Ali's views run as prom root to read the existing private files, but
present them only as container root (UID/GID 100000), with `ro` and `go=`.
Their underlying production ownership/modes remain unchanged. CT mount entries
`mp0`, `mp1`, `mp2`, `mp4`, `mp5`, `mp7` and `mp8` all use `ro=1`.
Only repository `mp3` and Kopia's own state `mp6` are writable.

Bindfs concurrency uses **uniform forced ownership**, never caller-dependent
`mirror` rules. The repository still creates files as NAS owner `1000:100`;
no new network grants, NAS recipients or credential copies are needed.
The source views cannot create, alter or delete files. See the
[upstream concurrency caveat](https://bindfs.org/docs/bindfs.1.html#BUGS).

For an install or rollback:

1. Check both repositories' source/task status and verify services. Wait for
   active backup/maintenance work to finish before stopping CT 111.
2. Back up `/etc/fstab`, `/etc/pve/lxc/111.conf`, and any existing
   `pve-container@111.service.d/kopia-mounts.conf` into a dated root-only
   directory on prom. Record the old `/run/current-system` in the CT.
3. Shut down CT 111 cleanly. Unmount the old bindfs views, leaving the actual
   Synology NFS mount and production ZFS datasets mounted.
4. Replace only the four target-view entries from `prom-mounts.fstab`; install
   the container drop-in. Create `/mnt/kopia-sources` as `0700 root:root` and
   its two mountpoints. Run `systemctl daemon-reload` and start each view's
   mount unit. `RequiresMountsFor` makes a failed view prevent container startup
   instead of exposing an empty source directory.
5. Set the source mappings with `pct set 111`:
   `--mp0 /mnt/tower-data,mp=/mnt/data,ro=1`,
   `--mp4 /mnt/kopia-sources/music,mp=/mnt/virtio/Music,ro=1`, and
   `--mp5 /mnt/kopia-sources/ali-cratedigger,mp=/mnt/virtio/ali-cratedigger,ro=1`.
6. Start CT 111, verify the mounts' ro/rw flags, translated reads, unchanged
   original file modes and repository marker. Deploy the signed Kopia closure
   through the [push-deploy path](../infrastructure/push-deploy.md).
7. Run fresh snapshots of the affected sources. Require zero errors and restore
   formerly unreadable canaries to a temporary location for hash comparison.

Rollback: stop CT 111, restore the backed-up fstab, container config and drop-in
(remove the new drop-in if none existed), unmount the changed views, run
`systemctl daemon-reload`, mount the original views and start CT 111. This
restores the previous mapping without altering source data or repository blobs;
it also restores the old permission problem, so use it only for recovery.

## Gotchas worth remembering

- **LXC bind mounts DO appear as systemd `.mount` units** inside the container
  (`mnt-mum.mount` etc.), so `RequiresMountsFor` resolves normally.
- **Do not hardcode mount-unit names.** `mountDepsFor` used to map path prefixes
  to unit names (`/mnt/mum` → `mnt-mum.automount`), which encoded doc2's layout
  and broke here. It now uses `unitConfig.RequiresMountsFor` and lets systemd
  resolve whatever backs each path.
- **Do not create a ZFS dataset over a populated directory.** `zfs create
  nvmeprom/containers/kopia` shadowed the live kopia state. Recovery: snapshot
  the *parent* dataset and read the hidden contents from
  `/nvmeprom/containers/.zfs/snapshot/<snap>/kopia/`.
- **The cache locations differ per instance.** photos uses
  `../.cache/kopia/<id>` (i.e. `/mnt/virtio/kopia/.cache`), mum uses
  `.cache/kopia/<id>` (i.e. `/mnt/virtio/kopia/mum/.cache`). Restore both.
- **Never mount the repo with `x-systemd.automount` as a bind source.** The CT
  would bind the autofs trigger rather than the NFS mount and see an empty
  repository.
- **A tag-less join is rejected.** prom's tailnet entry must exist in the policy
  *before* it runs `tailscale up --advertise-tags=...`.

## prom joins the tailnet, narrowly

mum's Synology is reachable only over Tailscale, so prom now holds a tailnet
identity under `tag:backup-egress`: exactly one egress grant (`kerrynas tcp:2049`),
zero inbound, no routes, no DNS takeover, no Tailscale SSH, shields up. Verified
in both directions. See `tailscale/acl.hujson`.

## An incidental discovery

doc2's last pfSense snapshot was **1,278 files / 1.1 GB**. The first snapshot from
the CT was **53,863 files / 6.3 GB** of the same tree. doc2's pfSense backups had
been materially incomplete — a milder form of the same submount problem — and the
migration fixed it as a side effect.

## Rollback

doc2's `pfsensebackup` pool and its zvol are deliberately left in place and
untouched. To go back: re-add the kopia block to `hosts/doc2/configuration.nix`,
point `syncoidPfsense.target` back at `pfsensebackup`, disable kopia on the CT,
and deploy both.

## Related

- `docs/wiki/infrastructure/pfsense-backup.md` — the replication chain
- `docs/wiki/infrastructure/nixos-proxmox-lxc-guide.md` — the general LXC recipe
- `docs/wiki/services/kopia.md` — the service itself
