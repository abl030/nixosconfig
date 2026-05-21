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

## Open audit items (2026-05-20)

The audit of which other services on doc2 share paperless's broad-`/mnt` scope or its `ReadWritePaths`-through-symlink fragility is tracked separately. Add findings here when they land.
