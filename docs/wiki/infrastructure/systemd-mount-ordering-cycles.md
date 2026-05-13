# systemd mount ordering cycles: `_netdev` and target placement

**Date researched:** 2026-05-13
**Status:** Active rule; fix applied to the one offender in `paperless.nix`.
**Affects:** any `fileSystems.<path>` entry whose source path lives on a network filesystem (NFS, CIFS, sshfs, etc.) and lacks `_netdev`.

## The failure

On 2026-05-13, doc2 was rebooted twice (13:27, 13:33) after tower NFS went down. When NFS came back, **`gatus.service` and `webdav.service` never started**. Both were `inactive (dead)` with zero journal entries this boot — they had never been *attempted*.

Boot log at 13:33:00 showed six ordering cycles, all rooted in one mount, all resolved by systemd deleting start jobs:

```
mnt-data.mount: Found ordering cycle: network-online.target/start after
NetworkManager-wait-online.service/start after sysinit.target/start after
systemd-update-done.service/start after local-fs.target/start after
mnt-data-Life-Meg\x20and\x20Andy-Paperless-Import-scans.mount/start after
mnt-data.mount/start - after network-online.target

mnt-data.mount: Job network-online.target/start deleted to break ordering cycle
```

`network-online.target/start` was deleted **twice**. Every service with `Requires=network-online.target` (gatus directly, webdav via `Requires=mnt-data.mount → Requires=network-online.target`) became unschedulable. `Dependency failed for Multi-User System` also fired.

## Why `_netdev` matters

`systemd-fstab-generator` reads `fileSystems` entries and produces `.mount` units. Each unit's target placement depends on `_netdev`:

| fstab option | Goes into | Ordered |
|---|---|---|
| `_netdev` present | `remote-fs.target` | After `network-online.target` |
| `_netdev` absent | `local-fs.target` | Before `network-online.target` |

The placement is structural, not advisory. It controls which target `Before=` and `Wants=` the generated unit gets, which controls when in the boot graph the mount can be attempted.

## The cycle topology

The paperless module declared a bind mount at `/mnt/data/Life/Meg and Andy/Paperless/Import/scans` sourcing from `/mnt/data/Life/Meg and Andy/Scans`. Both paths live on NFS, but the unit options listed only `bind`, `x-systemd.requires=mnt-data.mount`, `x-systemd.after=mnt-data.mount` — no `_netdev`.

So the unit landed in `local-fs.target`. Combined with the explicit `mnt-data.mount` dependency, the cycle became:

```
local-fs.target
    └─ After ─▶ paperless-import-scans.mount      (bind, no _netdev)
                    └─ After ─▶ mnt-data.mount    (explicit x-systemd.after)
                                    └─ After ─▶ network-online.target   (NFS auto-dep)
                                                    └─ After ─▶ NetworkManager-wait-online.service
                                                                    └─ After ─▶ sysinit.target
                                                                                    └─ After ─▶ local-fs.target   ← cycle
```

systemd's ordering analyzer detects this at job-enqueue time and breaks it by deleting one job from the cycle. The choice is **non-deterministic across boots** — depends on traversal order. On most boots an irrelevant job is deleted and the system comes up healthy. On 2026-05-13, the analyzer picked `network-online.target/start` and the cascade dropped multi-user.target.

The cycle was present in every boot since the bind mount was added (2026-04-30, commit `3cdb3ced`). It only manifested as user-visible breakage when systemd happened to delete a critical job.

## The fix

Add `_netdev` (and `nofail` for resilience) to the bind mount options:

```nix
options = ["bind" "_netdev" "nofail" "x-systemd.requires=mnt-data.mount" "x-systemd.after=mnt-data.mount"];
```

`_netdev` is the cycle-breaker. With the unit in `remote-fs.target`, the chain becomes `remote-fs.target → bind.mount → mnt-data.mount → network-online.target`, which is acyclic.

`nofail` is defensive — prevents `multi-user.target` from failing if the bind itself ever errors (e.g. source path doesn't exist after some future refactor). It does **not** mask failures from `switch-to-configuration-ng`, whose failed-unit scan ignores `nofail` (verified in [`nfs-over-tailscale.md`](nfs-over-tailscale.md)).

`x-systemd.mount-timeout` is **not** needed here. That option exists to bound the Tailscale-readiness race documented in [`nfs-over-tailscale.md`](nfs-over-tailscale.md). A bind mount is an in-kernel `mount(MS_BIND)` syscall — once the source path is reachable (i.e. `mnt-data.mount` is up), the bind returns synchronously. No timeout headroom required.

## The rule

> **Any `fileSystems.<path>` entry whose source path lives on a network filesystem MUST include `_netdev` in its options**, even if the entry itself is a bind mount, overlay, or fuse mount that doesn't appear "network-y" from the option set. The reason is target placement, not network detection — `_netdev` is what tells systemd-fstab-generator to use `remote-fs.target` instead of `local-fs.target`.

This applies to:

- Bind mounts of NFS subdirectories (the case here)
- Bind mounts of CIFS, sshfs, or any other network filesystem path
- fuse mounts (mergerfs, rclone) that union network paths — though our fuse units use `unitConfig.RequiresMountsFor` rather than fstab, so the analyzer reaches the same conclusion via different mechanics
- Overlay mounts where any layer is on a network filesystem

It does **not** apply to:

- Bind mounts where source is on local storage (`/var/lib/...`, `/etc/...`)
- Virtiofs mounts — those are `mount.virtiofs`, a Proxmox/qemu transport, and don't carry the NFS auto-dep on `network-online.target`

## Why this latency-bombs

Three properties combine to make this class of bug particularly nasty:

1. **Silent until triggered.** systemd's analyzer resolves the cycle on every boot, but the *resolution* is invisible unless it deletes a job whose absence is user-visible. The cycle warning is in the journal at boot but easy to miss.
2. **Non-deterministic.** Same code, same hardware, different boots can produce different deletions. So testing one good boot doesn't prove the absence of a bad boot.
3. **Worsens with NFS instability.** When `mnt-data.mount` fails, the analyzer has to do more work to compute the dependency graph, increasing the chance of choosing a destructive deletion.

A cycle warning in the journal is **not** a "systemd is being noisy" event — it's a latent bug waiting for the right boot to detonate.

## Audit

`grep -rn 'options.*\[.*"bind"' modules/ hosts/` across the entire repo on 2026-05-13: **one** offender, `modules/nixos/services/paperless.nix:56`. Fixed in the same change that introduced this wiki page.

If a future PR adds another bind/overlay/fuse mount on top of a network path, the rule above is mirrored in `.claude/rules/nixos-service-modules.md` (Anti-Patterns).

## Sources

- [systemd.mount(5) — `_netdev`](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html#_netdev)
- [systemd-fstab-generator(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html) — generator behaviour for fstab entries
- [systemd.special(7) — `remote-fs.target` vs `local-fs.target`](https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html)
- [`nfs-over-tailscale.md`](nfs-over-tailscale.md) — related cascade-restart race; same fleet pattern (`_netdev` + `nofail`)
