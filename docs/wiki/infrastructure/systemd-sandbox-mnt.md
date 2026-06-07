# Sandboxing /mnt for systemd services on doc2

**Status:** Active pattern (paperless as of 2026-05-20).
**Researched:** 2026-05-20.
**Related issues:** This page, [systemd-mount-ordering-cycles.md](systemd-mount-ordering-cycles.md), `docs/wiki/nixos-service-modules.md`.

## Why this exists

doc2 hosts ~20 services. Most of them open one or two NFS subdirs but inherit the host's full `/mnt` tree into their unit namespace. Concretely, when paperless was inspected on 2026-05-20 its `paperless-task-queue` could read every byte of:

| Path | Mode in namespace |
|---|---|
| `/mnt/data` | ro (entire tower data export) |
| `/mnt/appdata` | ro (entire tower appdata export — every other service's state) |
| `/mnt/mum` | ro (kerrynas backup target) |
| `/mnt/mirrors` | ro |
| `/mnt/virtio` | ro |
| `/mnt/virtio/Music` | ro |

That is the default behaviour of `ProtectSystem=strict` + `PrivateMounts=yes` — those options privatise the namespace and bind `/usr`/`/boot`/`/etc` ro, but they do **not** narrow the user-managed `/mnt/*` tree. Every host mount is inherited as-is.

For paperless the legitimate set is three paths: scans (rw), media (rw), state dir (rw). Everything else is implicit blast radius for a compromised paperless worker.

## The failure mode that motivated the change

On 2026-05-20 paperless started throwing:

```
[Errno 30] Read-only file system: '/mnt/data/Life/Meg and Andy/Paperless/Documents/media.lock'
```

while the directory was demonstrably writable from a shell as the `paperless` user. Inspection of `/proc/<pid>/mountinfo` for the three failing units showed `/mnt/data` mounted ro with **no rw bind mounts underneath** — the bind mounts that should have been created from `ReadWritePaths=/var/lib/paperless-media` (a symlink to `/mnt/data/Life/Meg and Andy/Paperless/Documents`) were missing.

A fourth unit (`paperless-web`) restarted later in the day and got the bind mounts correctly. The three units that started at the same instant as a `switch-to-configuration` reload at 13:59:27 did not.

Root cause is a race between the unit's namespace setup and concurrent mount activity on `/mnt/data` (NFS automount, watchdog probes, switch-to-configuration touching mount units). When systemd resolves a `ReadWritePaths=` symlink whose target is on a contested NFS mount, it can fail to create the rw bind mount **and proceed without error** — per `systemd.exec(5)`, `ReadWritePaths`/`ReadOnlyPaths`/`InaccessiblePaths` skip missing sources silently:

> If the path itself or any of its parents do not exist on the host, the corresponding mount will be skipped.

The unit then runs with a read-only view of the NFS path. First write fails with `EROFS`.

## The pattern we adopted

For each paperless systemd unit:

```nix
serviceConfig = {
  TemporaryFileSystem = "/mnt";
  BindPaths = [
    ''/mnt/data/Life/Meg\ and\ Andy/Paperless/Documents:/mnt/paperless-media''
    ''/mnt/data/Life/Meg\ and\ Andy/Scans:/mnt/paperless-consume''
    "/mnt/virtio/paperless"
  ];
};
```

- `TemporaryFileSystem=/mnt` replaces the whole `/mnt` tree with an empty tmpfs inside the unit's mount namespace. The host namespace is untouched.
- `BindPaths=src:dst` binds each needed path into that tmpfs at a chosen destination. Destinations are space-free, sources keep their literal names.
- **`BindPaths` is fail-loud.** If the source is missing or unbindable the unit fails with `status=226/NAMESPACE` and a `Failed to set up mount namespacing: <path>: <reason>` message in journald. This is the inverse of `ReadWritePaths`'s silent-skip behaviour and is the property that turns today's incident class into an alert.

The errorPattern entries for paperless include `Failed at step NAMESPACE` on every unit (`paperless-web`, `paperless-consumer`, `paperless-scheduler`, `paperless-task-queue`), so a future bind-setup failure pages via Gotify within ~5 minutes instead of being discovered by a user-uploaded scan.

### Escaping spaces in `BindPaths`

The source path `/mnt/data/Life/Meg and Andy/...` contains literal spaces. Two escape forms were tested:

| Form | In unit file | Works |
|---|---|---|
| `\x20` | `BindPaths=/.../Meg\x20and\x20Andy/...` | **No** — taken as literal `\x20` by the BindPaths parser, source not found |
| `\ ` | `BindPaths=/.../Meg\ and\ Andy/...` | **Yes** — systemd unescapes to a literal space at parse time |

In Nix, the indented-string form `''/.../Meg\ and\ Andy/...''` writes the unit value as `\ ` directly (single backslash followed by space). Plain `"..."` strings work too with `\\ ` (the doubled backslash collapses to one).

### What about the upstream module's `ReadWritePaths`?

The upstream nixpkgs paperless module still sets `ReadWritePaths={consumptionDir, dataDir, mediaDir}`. Inside our sandboxed namespace those paths exist (we bind them in) and are already rw (BindPaths defaults to rw). So upstream's `ReadWritePaths` becomes redundant but harmless. No need to override.

## When to apply this pattern to a new service

Use the `TemporaryFileSystem=/mnt` + `BindPaths` pattern when **all** of the following are true:

1. The service runs on a host with multiple `/mnt/*` entries that aren't all needed by this service.
2. The service writes to a path that's reached through symlinks or whose source has spaces — i.e. the cases where `ReadWritePaths` is fragile or impossible.
3. The service is stateful enough that a silent ro→rw degradation would be a real outage (not a stateless cron).

Skip the pattern if the service genuinely needs broad `/mnt` access (e.g. `kopia`, `tdarr-node`) or if it doesn't bind-mount NFS paths at all (most virtio-only services already have tight scope by accident).

## Audit findings + progress (#257)

The full audit (every doc2 service classified A–E by current sandbox state) lives in [issue #257](https://github.com/abl030/nixosconfig/issues/257). Progress:

### Batch 1 — Class A + forgejo (landed 2026-06-07, PR #263)

Applied the `TemporaryFileSystem=/mnt` pattern to the first batch. All verified on doc2 via `/proc/<pid>/mountinfo` showing only the bound paths:

| Service | Shape | Bound back |
|---|---|---|
| atuin, stirling-pdf, gatus, gotenberg, tika, rtrfm-nowplaying | blank `/mnt`, no bind | (nothing — state in DB container / `/var/lib`) |
| uptime-kuma, seerr | blank `/mnt` + 1 virtiofs dir | `/mnt/virtio/{uptime-kuma,overseerr}` (was `ReadWritePaths` → fail-loud `BindPaths`) |
| forgejo, forgejo-dump | blank `/mnt` + 2 binds | `/mnt/virtio/forgejo` (stateDir) + `/mnt/data/.../forgejo-dumps` (NFS) |

**Two learnings folded into [the rules doc](../nixos-service-modules.md) (Sandbox patterns):**

1. **Order the unit after its bind sources** — `unitConfig.RequiresMountsFor = [ <each bound /mnt path> ]`. `BindPaths` is fail-loud, so a unit that starts before its virtiofs/NFS mount dies with `226/NAMESPACE` at boot. (Old `ReadWritePaths` masked this by silently skipping the unmounted source.)
2. **Upstream `ReadWritePaths` under a blank `/mnt` can break the namespace.** forgejo's upstream module lists `${stateDir}/data/lfs` in `ReadWritePaths`; with LFS disabled that dir doesn't exist. In the host namespace `ReadWritePaths` skip-if-missing handles it, but under `TemporaryFileSystem=/mnt` the self-bind can't be skipped → `226/NAMESPACE`. Fix: once `BindPaths` covers the parent dir rw, clear the redundant upstream list with `ReadWritePaths = lib.mkForce [];`. **Check any service whose upstream module sets `ReadWritePaths` under `/mnt` before converting it.**

### Batch 2 — Class C (landed 2026-06-07)

The unhardened set (`ProtectSystem=no`, full `/mnt` **RW**-visible). Done in three sub-batches, each deployed + verified on doc2:

| Service | Shape | Notes |
|---|---|---|
| tautulli, gotify-server | `ProtectSystem=strict` + bind 1 virtiofs dataDir | sole path each writes |
| discogs-api | `ProtectSystem=strict` + blank `/mnt`, no bind | stateless root API (DB over TCP) |
| discogs-import | blank `/mnt` + bind mirror dir | monthly root oneshot |
| mealie | blank `/mnt` only | state already binds virtiofs→`/var/lib/mealie` |
| fava (+ clone/pull) | `ProtectSystem=strict` (fava) + bind virtiofs dataDir | replaced fava's `ReadWritePaths` |
| webdav | `ProtectSystem=strict` + bind **only** the Zotero Library NFS dir | space-bearing path, escaped |
| audiobookshelf (+ cache-cleanup) | blank `/mnt` + bind state + declared library dirs | new `libraryDirs` option; real path is `/mnt/data/Media/Books/Audiobooks` |
| cratedigger ×6 app units | blank `/mnt` + bind state + `/mnt/virtio/Music` + `cfg.downloadDir` | **biggest win** — ran as root seeing `/mnt/backup/pfsense`, `/mnt/appdata`, `/mnt/mum`; validated live (pipeline imported music inside the sandbox with zero errors) |

**Class C learnings:**

- **`ProtectSystem=strict` added only where the writable-path set is known** (single-user services writing one dataDir, or stateless). Skipped for audiobookshelf and the cratedigger app units (large Node/Python apps with unpinned write paths) — there the `/mnt` narrowing alone is the blast-radius win #257 targets.
- **Verify against the resolved value, not the module default.** cratedigger's `downloadDir` default is `/mnt/data/Media/Temp/slskd`, but doc2 overrides it to `/mnt/virtio/music/slskd` (lowercase, ≠ the capital-M `/mnt/virtio/Music` beets tree). Always read the actual `systemctl show -p BindPaths` and the host override, not the option default, when sanity-checking a namespace.
- **Audit guesses need confirming.** The audit listed audiobookshelf's library as `/mnt/data/Media/Audiobooks`; the real path (from the ABS sqlite DB) is `/mnt/data/Media/Books/Audiobooks`. Pulled it from `libraryFolders` rather than trusting the issue.

### Remaining (follow-up batches)

- **Class D / immich** — `immich-server` (shares mount namespace with ML subprocess + asset-edit machinery), `immich-machine-learning`, plus free wins on nginx/grafana (`PrivateMounts=yes` + blank `/mnt`).
- **Class E** (kopia-mum/photos, nspawn `*-db` containers) — legitimately broad / already tight, leave alone.
