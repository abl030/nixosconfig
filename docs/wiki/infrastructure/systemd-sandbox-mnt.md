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

### Batch 3 — Class D / immich + nginx (landed 2026-06-07)

| Service | Shape | Notes |
|---|---|---|
| immich-server | blank `/mnt` + bind `mediaLocation` | only the photo library; DB over TCP so private namespace is safe (the old "loses nspawn nspath" worry was moot — it already ran `PrivateMounts=yes`) |
| immich-machine-learning | blank `/mnt` + bind `MACHINE_LEARNING_CACHE_FOLDER` when under `/mnt` | virtiofs model cache |
| grafana | blank `/mnt` + bind `cfg.dataDir/grafana` | data dir is on virtiofs (= WorkingDirectory); sandbox lives in `loki-server.nix` which owns the path |
| nginx | **secure-by-default**: blank `/mnt` in the shared `homelab.nginx` module | see below |

**The nginx secure-by-default pattern (the important one).** Rather than enumerate which hosts' nginx is "just a proxy," `homelab.nginx` now sets `TemporaryFileSystem=/mnt` unconditionally — so every host, and every future VM, starts with nginx blind to `/mnt`. Any module that defines an nginx vhost serving static files from `/mnt` **opens that one hole itself**, co-located with the vhost:

```nix
# in the module that sets `services.nginx.virtualHosts.<x>.root = <path under /mnt>`
systemd.services.nginx = {
  unitConfig.RequiresMountsFor = [ <root> ];
  serviceConfig.BindPaths = [ <root> ];   # list-merges across modules
};
```

Audited every fleet `services.nginx...root`: only podcast is under `/mnt` (smokeping → `/var/lib`, nix cache → `/var/cache`). This means a future static-from-`/mnt` vhost that forgets the bind fails **loud** (nginx `226/NAMESPACE`) instead of silently widening the blast radius — the failure mode points you straight at the missing bind.

**The flip side (2026-06-18): a *correct* bind still fails if the backing mount is stale — bind the mount ROOT, not the leaf (fixed forgejo#3, 2026-06-22).** `/mnt/data/Media/Podcasts` is NFS from tower (`192.168.1.2:/mnt/user/data`, Unraid). The original `BindPaths=[podcastDir]` made systemd resolve that **leaf** path inside nginx's private namespace on **every (re)start — including the reload `nixos-rebuild switch` performs**. Unraid's `/mnt/user` is an shfs FUSE union that reassigns a directory's inode whenever it's written — and the podcast downloader drops new mp3s straight into `Podcasts/` (plus the array mover) — so that subdir's NFS filehandle **flaps stale**. Whenever it was stale at reload time, nginx died `Failed at step NAMESPACE … Stale file handle` → `switch-to-configuration` exit 4 → the *whole rebuild* failed (the running nginx kept serving its old config, so it was a *deploy* failure, not an outage). It fired on essentially **every** deploy.

**Fix:** bind the **mount root** `/mnt/data` instead of the churning leaf, read-only:

```nix
systemd.services.nginx = {
  unitConfig.RequiresMountsFor = ["/mnt/data"];
  serviceConfig.BindReadOnlyPaths = ["/mnt/data"];
};
```

The mount-root handle is established at mount time and stays valid (only an actual umount invalidates it); nginx resolves the `Media/Podcasts` subdir **lazily at request time**, which already self-heals on ESTALE (a fresh lookup revalidates). So namespace setup never touches the flapping leaf and the deploy stops failing — no watchdog/oneshot/remount machinery needed. Read-only because the webserver only reads; the downloader (`webhook.service`) writes in its own, separately-sandboxed namespace, so widening leaf→root doesn't grant nginx write to the share.

**General rule:** when an nginx `/mnt` hole points at a **write-churned NFS leaf** (shfs/Unraid especially), bind a stable ancestor (ideally the mount root) **read-only** and let nginx walk to the leaf at request time. Binding the leaf directly couples every reload to that leaf's handle staying valid. For non-churning virtiofs dirs the plain `BindPaths=[<root>]` leaf pattern above is still fine. The candidate fixes that *don't* work here, for the record: `x-systemd.automount`+idle-timeout never fires on doc1 (≈15 services pin `/mnt/data` continuously, so it never idles to remount); `hard`/`soft`/`timeo`/`retrans` tuning can't help ESTALE (a definitive server response, not a timeout); a remount-watchdog is a heavy hammer on a 15-service shared mount. The permanent root-cause fix is server-side on Unraid (export the disk/cache path directly for stable XFS inodes, or shfs `fuse_remember=-1`).

**Class D learnings:**

- **Read the actual `WorkingDirectory`/env, not assumptions.** grafana looked like a "needs nothing under `/mnt`" free win, but its data dir is `cfg.dataDir/grafana` on virtiofs → a no-bind blank `/mnt` failed `200/CHDIR`. Same lesson as cratedigger's `downloadDir`: confirm against the running unit.
- **Put the bind where the path is defined.** grafana's sandbox went in `loki-server.nix` (owns `services.grafana.dataDir`), not `alerting.nix` (only adds restartTriggers). Keeps the `/mnt` hole next to the path it needs.

### Batch 4 — fleet sweep (landed 2026-06-07)

After Class A–D, ran an empirical sweep on doc2 — for every running service, counted `/mnt` mounts in `/proc/<pid>/mountinfo` and checked for `TemporaryFileSystem`. Anything broad + unsandboxed got triaged:

| Service | Action |
|---|---|
| tempo, mimir, loki | blank `/mnt` + bind each one's virtiofs state subdir (same as grafana) |
| **slskd** | **a missed Class B item** — internet-facing P2P daemon seeing all of `/mnt` incl. `/mnt/backup/pfsense`. Blank + bind `downloadDir` (rw) and the shared library (read-only) |
| redis-immich/-paperless/-cratedigger | blank `/mnt`, no bind (state in `/var/lib`) |
| alert-bridge, smokeping (+fcgiwrap) | blank `/mnt`, no bind |

**Deliberately left broad (verified out of scope):**

- **OS daemons** — `sshd`, `systemd-*`, `nix-daemon`, `dbus-broker`, `NetworkManager`, `qemu-guest-agent`, etc. Root system services that need broad access. **`prometheus-node-exporter` specifically MUST see all mounts** — per-mount disk metrics are its job.
- **OCI `podman-*`** — the 22-mount count is the podman *runtime's* host namespace; the container's own `/mnt` view is set by `--volume` flags, not systemd sandboxing.
- **nspawn `container@*-db`** and **`kopia-mum`/`kopia-photos`** — Class E (DB scope tight via nspawn; kopia legitimately broad by design).
- **`alloy-loki`** — log-collection agent; left for now (reads journal/targets, sandboxing risks breaking collection).

**slskd switch-to-configuration race (important deploy gotcha).** On the deploy that added slskd's sandbox, slskd was *actively downloading*; `switch-to-configuration`'s live restart left it in a private mount namespace that still held the **old** (full-`/mnt`) mount table — `systemctl show` reported the new `TemporaryFileSystem=/mnt` + binds, but `/proc/<pid>/mountinfo` showed all 23 host mounts. A clean `systemctl restart slskd` applied it correctly (down to 4 mounts). So: **for a heavily-loaded service, verify the namespace actually narrowed after a deploy — don't trust `systemctl show`; read `mountinfo`.** A clean boot (e.g. the nightly rolling-update reboot) applies it correctly, so it self-heals; the live-restart-during-deploy is the only window where it can lag.

### Remaining

- **Class E** (kopia-mum/photos, nspawn `*-db` containers) — legitimately broad / already tight, leave alone.
- **`alloy-loki`** — optional; sandbox only after confirming its read targets.
