# Ali Cratedigger — isolated Yoto music acquisition

**Last updated:** 2026-08-24
**Status:** deployed; Tailscale node enrolled; external share acceptance still required
**Owner:** `modules/nixos/services/ali-cratedigger.nix`
**Application URL:** `https://ali-music.ablz.au`
**Download URL:** `https://yoto.ablz.au/Music/`

## Purpose

This is a low-volume, normal-person deployment of Cratedigger for Ali's kids'
Yoto music. It deliberately optimises for "request an album, download one ZIP
on a phone" rather than Andy's archival library policy.

## Authority boundaries

Ali's instance runs in the `ali-cratedigger` NixOS container on doc2. The
container shares the host network namespace only because the upstream module is
singleton-shaped and its nginx gateway must be reachable from the sandboxed
Tailscale/Caddy proxy. The gateway listens only on loopback and the private
`podman0` bridge address; the host firewall opens its port only on `podman0`.
There is no LAN or public-internet listener.

The instance has independent:

- PostgreSQL pipeline database;
- Redis service;
- Cratedigger state and processing tree;
- Beets SQLite catalog and incremental-import state;
- Beets music library;
- systemd workers, timers, Unix socket, and nginx gateway.

It shares only:

- the slskd service and download tree, with each pipeline database retaining its
  own positive request-ownership ledger;
- read-only MusicBrainz, Discogs, and LRCLIB mirrors;
- the existing deployment-rendered slskd and Discogs credentials.

No Plex or Jellyfin notifier is enabled. Ali cannot mutate Andy's Beets catalog
or archival library through this deployment.

The shared slskd boundary is deliberately logical rather than a separate
authority. If both instances simultaneously select the exact same Soulseek peer
and remote filename, their independent ledgers cannot coordinate that queue key.
One importer may consume the shared handoff first and the other will retry the
download; it does not gain authority over the other Beets catalog or library.
Ali's low-volume family use makes that rare extra-download failure mode
acceptable. A compromise of either pipeline's slskd credential retains the same
slskd and handoff-tree blast radius as the primary deployment.

## Storage

| Data | Path |
|---|---|
| Cratedigger state | `/mnt/virtio/ali-cratedigger/state` |
| Processing/staging | `/mnt/virtio/ali-cratedigger/{processing,staging}` |
| Beets database/log | `/mnt/virtio/ali-cratedigger/beets-db` |
| PostgreSQL | `/var/lib/ali-cratedigger/postgresql` |
| Published music library | `/mnt/data/Media/Yoto/Music` |
| Shared slskd handoff | `/mnt/virtio/music/slskd` |

Kopia `mum` covers both `/mnt/virtio/ali-cratedigger` and the complete
`/mnt/data/Media/Yoto` publication tree.

## Yoto format policy

Search preference admits lossless sources plus MP3 and AAC, but excludes Opus
and Ogg. Verified lossless sources are transcoded by Cratedigger to **MP3 V0**.
Existing MP3 and AAC/M4A sources remain as-is; all are supported by Yoto.

`ali-yoto-zip.timer` scans every five minutes. For each Beets album directory it
creates `<album>.zip` containing a top-level album folder, supported audio, and
cover artwork. Archives use `ZIP_STORED`, are written to a same-directory
partial file, fsynced, and atomically renamed. A content digest in the ZIP
comment makes unchanged reruns no-ops and refreshes an archive after track or
artwork changes. If Beets moves every published track out of an old album
directory, the reconciler removes an orphan only when the ZIP's ownership
comment proves it created that archive; foreign ZIPs are never deleted. Symlinks
and unsupported formats are never included.

The ZIP is intentionally inside the Beets album directory. Beets does not track
it; occasional untracked-file noise on this low-volume instance is accepted.

## Access model

`ali-music.ablz.au` and `yoto.ablz.au` are separate tagged Tailscale share nodes.
The applications have no additional login: node sharing is the authorization
boundary. Both carry `tag:share`, preserving the default-deny share-to-fleet
policy.

First deployment of the new application node:

```bash
podman logs ts-ali-music
```

Open the printed login URL, confirm the node is tagged `tag:share`, then share
`ali-music` with Ali's tailnet account. The existing `yoto` node must remain
shared with her so she can download the finished ZIPs.

The work laptop (`tag:cullen`) is deliberately granted HTTPS only to the pinned
`ali-music` and `yoto` nodes. It does not receive tag-wide access to other share
sidecars.

### Plex

Plex on tower publishes the finished catalog as the separate music library
`Ali Music`. No prom-to-tower NFS export is involved: doc2's
`/mnt/data/Media/Yoto/Music` is already backed by tower's
`/mnt/user/data/Media/Yoto/Music`, and Plex's existing read-only `/media3` bind
sees it at `/media3/Yoto/Music`.

The library uses the Plex Music scanner/agent, prefers embedded Beets metadata
and local artwork, and disables sonic analysis. Its visibility is `Exclude from
home screen`, so it does not add recommendations to the owner's feed. This is a
server-wide library preference, so Ali browses it as a library rather than
receiving its hubs on Home.

Plex library access is explicit rather than `allLibraries`: Ali's Plex account
`ali.barre` receives `Ali Music`; every other shared or managed user retains
exactly their pre-existing section list and does not receive it. The Plex server
owner remains able to administer and browse every server library, as required by
Plex; the owner cannot be denied a single owned section. Verify both the section
permission list and the scan result after changing Plex libraries, because a
user with `allLibraries` would inherit future sections automatically.

Ali's importer notifies Plex section 6 after a successful Beets import. It maps
the publication path `/mnt/data/Media/Yoto/Music` to Plex's read-only view at
`/media3/Yoto/Music`, allowing a narrow album-path refresh instead of rescanning
unrelated libraries. The container mounts the existing runtime Plex token at
`/run/cratedigger-secrets/PLEX_TOKEN`, read-only; no token is stored in Nix or in
the container's persistent state. `container@ali-cratedigger.service` is part of
the token producer's restart lifecycle so token replacement cannot leave the
single-file bind pinned to a stale inode.

## Operations

```bash
# Container and app health
systemctl status container@ali-cratedigger
machinectl shell ali-cratedigger /run/current-system/sw/bin/systemctl -- \
  --failed

# Run or inspect the independent pipeline
machinectl shell ali-cratedigger /run/current-system/sw/bin/systemctl -- \
  start cratedigger.service
machinectl shell ali-cratedigger /run/current-system/sw/bin/journalctl -- \
  -u cratedigger.service -n 100

# Ali's Beets catalog
machinectl shell ali-cratedigger /run/current-system/sw/bin/ali-beet -- ls -a

# Force ZIP reconciliation
machinectl shell ali-cratedigger /run/current-system/sw/bin/systemctl -- \
  start ali-yoto-zip.service

# Secret rotation: restart the producer; PartOf restarts the container so the
# slskd single-file bind sees the producer's replacement inode.
systemctl restart cratedigger-secrets-split.service
```

Uptime Kuma monitors `Ali Cratedigger (Tailnet)` at `/healthz`. The current Yoto
share monitor continues to check the top-level Books/Music listing.

## Migration and rollback

The one-time publication migration is an atomic rename on tower's Media share:

```bash
mkdir -p /mnt/data/Media/Yoto
mv /mnt/data/Media/Books/Yoto /mnt/data/Media/Yoto/Books
mkdir -p /mnt/data/Media/Yoto/Music
```

Before deployment, require that the old source exists and the new Books target
does not. While `Music` is still empty, roll back the complete data layout with:

```bash
rmdir /mnt/data/Media/Yoto/Music  # only while empty
mv /mnt/data/Media/Yoto/Books /mnt/data/Media/Books/Yoto
rmdir /mnt/data/Media/Yoto
```

After Ali has imported music, preserve it while restoring the old Books share:

```bash
systemctl stop container@ali-cratedigger.service
mv /mnt/data/Media/Yoto/Books /mnt/data/Media/Books/Yoto
# Leave /mnt/data/Media/Yoto/Music, the Beets DB, and PostgreSQL dormant.
test -d /mnt/data/Media/Books/Yoto
test -d /mnt/data/Media/Yoto/Music
```

Restore the old `yotoShare.shareDir`, deploy it, and verify the old Books URL
before removing any retained Ali state. A later retry must restore the same
Beets database, PostgreSQL state, and Music tree together; do not restore only
one member of that consistency set.

Configuration rollback removes `aliCratedigger.enable` and restores the old
Yoto `shareDir`; persistent databases and node state can remain dormant for a
later retry.
