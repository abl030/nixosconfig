# Jellyfin mergerfs metadata-branch ownership (igpu)

**Status:** repaired and guarded; the writer is still UNIDENTIFIED
**Date:** 2026-09-11 (guard relocated same day after it failed in practice)
**Hosts:** igpu (CT 107, unprivileged LXC on prom), doc2, prom (hypervisor)
**Code:** `hosts/doc2/configuration.nix` (the guard), `modules/nixos/services/mounts/fuse.nix` (the unions)

## What this page is about

Why the three mergerfs RW metadata directories on prom virtiofs must keep group
`users` + setgid, why the *owner* must stay inside igpu's LXC id map, and why
the guard lives on igpu rather than on prom.

## The layout

Each Jellyfin library is a mergerfs union of a read-write metadata branch and a
read-only media branch:

| union | RW branch (metadata) | RO branch (media) |
| --- | --- | --- |
| Movies | `/mnt/virtio/media_metadata/Movies` | `/mnt/data/Media/Movies` (tower NFS) |
| TV Shows | `/mnt/virtio/media_metadata/TV Shows` | `/mnt/data/Media/TV Shows` (tower NFS) |
| Music | `/mnt/virtio/media_metadata/Music` | `/mnt/virtio/Music` (prom virtiofs) |

The RW branch is where Jellyfin writes NFO, LRC and artwork. `fuse-mergerfs-music`
hard-fails its `ExecStartPre` (`test -w /mnt/virtio/media_metadata/Music`) if
that branch is not writable, so the union never comes up and the mount point
stays an empty directory.

## The 2026-09-10 incident

At 03:53:41 on 2026-09-10, all three directories were reset to host `root:root`
mode `0755`, non-recursively (everything below them kept gid 100 and setgid).

Consequences:

- igpu, an **unprivileged** container, maps container uid 0 → host 100000. Host
  uid 0 is outside that map, so the directories appeared as `nobody:nogroup` and
  group `users` lost write.
- `fuse-mergerfs-music` hit its start limit and stayed down for a full day.
  `/mnt/fuse/Media/Music` was an empty directory, not a mount.
- The nightly `nixos-upgrade` on igpu failed on that unit, and paged as
  "nixos-upgrade failed on igpu" — which named the symptom, not the cause.
- Movies and TV Shows had the **same** wrong ownership but their unions kept
  serving, purely because they had not restarted since 2026-09-04. They were
  primed to fail on their next restart.

**The cause was never identified.** Ruled out: cron on prom (none), an NFS
export of that dataset (not exported), a tmpfiles rule in this repo (none covers
those paths), and sudo on doc2 in that window (no entries). doc2 mounts
`/mnt/virtio` over virtiofs **without** id mapping, so doc2's root is the
hypervisor's root for these paths, which makes doc2 the most plausible origin.
Unproven.

### Jellyfin risk

This nearly cost the music library. Jellyfin 12.0 was deployed the same night and
its migration logged:

```
MigrateLinkedChildren: Library location /mnt/fuse/Media/Music/Beets is
inaccessible or empty, skipping file existence check
```

Music survived only because that particular routine skips empty locations. In the
same run Jellyfin deleted 414 rows for files it could not find. **An
empty-but-readable library directory is the dangerous shape** — it looks mounted
and simply appears to contain nothing. Repair the mount before letting a scan run.

## Why prom's own guard never worked

prom already had `/etc/tmpfiles.d/media-metadata-music.conf`:

```
d /nvmeprom/containers/media_metadata/Music 2775 root users -
```

It had **never run once**. `systemd-tmpfiles-setup` only runs at boot; prom last
booted 2026-06-29 and the rule was written 2026-08-20. It also covered Music
alone, and targeted owner `root`.

Two lessons:

1. **Cadence.** prom boots roughly every ten weeks, so a boot-only rule there is
   close to inert. doc2 and igpu both re-run tmpfiles on every `nixos-rebuild`,
   i.e. nightly. A guard belongs where it actually runs.
2. **The owner must be inside the container's id map**, so that igpu keeps
   working normally against it. Verified empirically from
   inside CT 107 with chown calls that set the ids to their existing values, so
   nothing changed but the permission check still applied:

   | target | owner | container root can chown? |
   | --- | --- | --- |
   | `media_metadata/Music` (then host root) | unmapped | refused, `EPERM` |
   | `media_metadata/Music/Beets` (host 165534) | mapped | succeeded |

   With owner `root` the container can never touch the invariant at all — which
   is exactly why it could not self-heal. Owner host 165534 = container `nobody`
   is inside the map and is what every directory below already uses.

   This same table is why the guard could not simply be placed on igpu either;
   see the next section.

## The guard lives on doc2, and here is why it moved

It was first placed on igpu, next to the unions. **That was wrong, and it failed
within the hour.** It is now in `hosts/doc2/configuration.nix`:

```nix
"z /mnt/virtio/media_metadata/Movies 2775 165534 100 -"
"z /mnt/virtio/media_metadata/TV\\x20Shows 2775 165534 100 -"
"z /mnt/virtio/media_metadata/Music 2775 165534 100 -"
```

The reason is the idmap asymmetry above. A guard on igpu can only **maintain**
correct ownership; it can never **restore** it, because the broken state is
precisely "owned by host root", which is outside igpu's map and unchownable from
inside the container. The only case the guard exists for is the one it cannot
handle.

doc2 mounts the same virtiofs **without** idmapping, so doc2's root is the
hypervisor's root on these paths and can chown them back. doc2 also rebuilds
nightly. `165534` is the host uid for container `nobody` (65534 plus the 100000
offset), i.e. an owner inside igpu's map so igpu keeps working normally.

This was proven the hard way: the igpu guard was deployed at 09:0x on
2026-09-11, and the directories were already root-owned from 08:59:04, so the
`z` rules silently failed with EPERM and the wrong ownership survived the
deploy.

- **`z`, not `d`.** `z` adjusts an existing path and never creates one. A `d`
  rule would create these directories if the virtiofs mount were late, shadowing
  the real mount — a worse failure than the one being fixed.
- **`\x20`** is how tmpfiles escapes the space in `TV Shows`. In the Nix source
  this is written `TV\\x20Shows`.
- **2775 + group `users`** is what grants the write. The owner is almost
  incidental; it only has to be inside the id map so igpu can enforce it.

prom's dormant rule was deleted at the same time, so one host owns this
invariant and there are not two rules targeting different owners.

## If it happens again

Symptom: `fuse-mergerfs-music` failed, `/mnt/fuse/Media/Music` empty, igpu's
nightly upgrade failing.

```bash
# check, from doc1
ssh root@prom 'stat -c "%n uid=%u gid=%g mode=%a" \
  /nvmeprom/containers/media_metadata/{Music,Movies} \
  "/nvmeprom/containers/media_metadata/TV Shows"'
```

Correct state is `uid=165534 gid=100 mode=2775`. To repair by hand:

```bash
ssh root@prom 'cd /nvmeprom/containers/media_metadata && \
  for d in Music Movies "TV Shows"; do chown 165534:100 "$d"; chmod 2775 "$d"; done'
ssh root@prom 'pct exec 107 -- /run/current-system/sw/bin/systemctl \
  reset-failed fuse-mergerfs-music.service'
ssh root@prom 'pct exec 107 -- /run/current-system/sw/bin/systemctl \
  start fuse-mergerfs-music.service'
```

Then confirm the mount is populated **before** any Jellyfin library scan runs.

## The writer is still unknown — this is a repair, not a cure

Both resets (2026-09-10 03:53:41, 2026-09-11 08:59:04) changed all three
directories plus `/nvmeprom/containers/Music` within the same few milliseconds,
non-recursively, at the exact second doc2 activated a new generation.

Ruled out so far:

- cron on prom (none), an NFS export of the dataset (not exported)
- prom's own tmpfiles rule (it had never run; now deleted)
- **doc2's tmpfiles** — `systemd-tmpfiles --create --dry-run` on doc2 touches
  `/mnt/virtio/Music`, `/mnt/virtio/Music/Incoming`, `/mnt/virtio/Music/Beets`
  and `/mnt/virtio/music/slskd*`, and never `media_metadata`
- sudo on doc2 in the window (no entries)

Note the partial explanation: `/nvmeprom/containers/Music` becoming `root:root
0755` **is** accounted for — that is cratedigger's `d /mnt/virtio/Music 0755 root
root` rule on doc2. The three `media_metadata` children are not.

So the guard repairs the damage on doc2's next activation, but if the unknown
writer runs *after* tmpfiles within the same activation it still wins. If this
recurs with the guard in place, that ordering is the answer, and the next step is
to bisect doc2's activation with a watch on the directories' ctime.

## Related

- `modules/nixos/services/mounts/fuse.nix` — the unions and the guard
- `docs/wiki/services/retired-container-stacks.md` — media stack history
