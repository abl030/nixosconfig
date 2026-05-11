# NFS over Tailscale: mount cascade pathology

**Date researched:** 2026-05-11
**Status:** Active workaround in place; root cause is upstream Tailscale bug.
**Affects:** any NFS (or other connection-oriented network mount) whose server is only reachable via the tailnet.

## The failure

On 2026-05-11, the nightly `rolling-flake-update` + `nixos-upgrade` chain failed
on proxmox-vm (doc1) with:

```
× mnt-mum.mount - /mnt/mum
  Active: failed (Result: timeout)
  Where: /mnt/mum
  What: 100.100.237.21:/volumeUSB1/usbshare
  Mounting timed out. Terminating.
```

`switch-to-configuration` returned exit 4. The whole upgrade was marked failed
even though every other unit activated cleanly.

This is rare — one failure in ~30 days of nightly upgrades — but the
underlying race is deterministic and gets worse over time.

## The pathology, layer by layer

### Layer 1 — Tailscale lies about readiness (upstream bug)

`tailscaled.service` runs `Type=notify`. It calls `sd_notify(READY=1)` —
which flips the unit from `activating` to `active` — *before* the
`LocalBackend` has finished initialising. The tailscale interface
(`tailscale0`) and its IPs aren't actually bindable for another ~5-30s
after the unit hits `active`.

Tracked upstream as [tailscale/tailscale#11504](https://github.com/tailscale/tailscale/issues/11504).
The async `LocalBackend` refactor moved tunnel setup off the start path,
but `Ready()` was never moved with it. Upstream's position is that this
is intended async behaviour — the fix lives in the new
[`tailscale wait`](https://tailscale.com/docs/reference/tailscale-cli) CLI
(1.96+), which blocks until the interface is actually bindable.

We're on 1.98, so the primitive is available.

### Layer 2 — our cascade restart amplifies the race

Our fstab entries (both `modules/nixos/services/mounts/external.nix` and
the duplicate in `modules/nixos/services/kopia.nix`) carry:

```
x-systemd.requires=tailscaled.service,x-systemd.after=tailscaled.service
```

`x-systemd.requires=` lowers to a hard systemd `Requires=` on the mount
unit. Per `systemd.unit(5)`:

> If one of the other units gets deactivated or its activation fails,
> this unit will be deactivated.

When `switch-to-configuration` upgrades the tailscale package (1.96 → 1.98
on the failing run), it issues `systemctl restart tailscaled.service`.
This **stops** then **starts** tailscaled. The stop phase cascade-stops
every unit with `Requires=tailscaled.service`, including `mnt-mum.mount`.
The start phase brings everything back, in dependency order.

So:

```
03:44:02  Unmounting /mnt/mum...           ← cascade-stop from tailscaled restart
03:44:02  Stopped Tailscale node agent
03:44:04  Started Tailscale node agent     ← service "active", but tunnel NOT ready
03:44:04  Mounting /mnt/mum...             ← mount.nfs fires immediately
03:45:34  Mounting timed out (90s)         ← tunnel still warming up
```

The mount unit's `After=tailscaled.service` ordering is satisfied as soon
as tailscaled hits `active` — i.e. before the tunnel is bindable. mount.nfs
runs into the readiness gap and stalls the full 90s timeout.

### Layer 3 — failed unit fails the upgrade

`smart-nixos-upgrade` invokes `switch-to-configuration`, which checks
`systemctl list-units --failed` after activation. Any failed unit ⇒ exit 4
⇒ the rolling update is marked failed and Gotify pages us.

The mount itself is **non-critical** — kopia's mum backup runs on doc2,
not doc1, and only consumes /mnt/mum when its scheduled timer fires. A
failed mount is benign for the system as a whole.

## Why it's been rare

`tailscaled.service` only gets restarted by switch-to-configuration when
the tailscale package version changes. That's monthly-ish cadence.

Each of those restarts is a race between:
- (1) tailscale tunnel becoming bindable
- (2) mount.nfs giving up after the 90s mount-timeout

(1) used to win consistently. As tailscale's async startup has grown more
elaborate over recent releases, (1) has been getting slower, and the
1.96 → 1.98 bump on 2026-05-11 was the first time (2) won.

This won't get better on its own. Expect more failures as Tailscale evolves.

## The fix

Three coordinated changes:

1. **Real readiness gate.** A `tailscale-wait.service` oneshot defined in
   `modules/nixos/services/tailscale/default.nix`:

   ```nix
   systemd.services.tailscale-wait = {
     description = "Wait for Tailscale interface to be bindable";
     after = ["tailscaled.service"];
     requires = ["tailscaled.service"];
     wantedBy = ["multi-user.target"];
     serviceConfig = {
       Type = "oneshot";
       RemainAfterExit = true;
       ExecStart = "${pkgs.tailscale}/bin/tailscale wait --timeout=120s";
     };
   };
   ```

   `tailscale wait` is the upstream-blessed primitive for this exact case.

2. **Mount depends on wait, not on tailscaled directly.** Replace
   `x-systemd.requires=tailscaled.service` with
   `x-systemd.requires=tailscale-wait.service`. The cascade chain becomes
   `tailscaled → tailscale-wait → mnt-mum.mount`; mount.nfs now runs
   only after the tunnel is actually bindable.

3. **Soft-fail belt-and-braces.** Add `nofail` so activation doesn't fail
   if `tailscale wait` itself times out (e.g. tailscale auth is broken).
   Add `x-systemd.mount-timeout=30s` so a genuine failure surfaces
   quickly instead of stalling 90s.

## What we considered and rejected

- **Just `nofail` alone.** Masks the failure but the mount still goes
  through a 90s stall every tailscale bump, and `mnt-mum.mount` lands in
  `failed` state until the next automount trigger. Doesn't fix the bug,
  just makes activation tolerate it.
- **Just `x-systemd.after=` without `Requires=`.** Cuts the cascade-stop,
  so the existing mount survives a tailscaled restart. But the tun
  device is recreated, breaking the underlying TCP. NFS hard mounts
  (our default — `hard,timeo=600,retrans=2`) loop forever on broken
  TCP, leaving stuck I/O and processes in `D` state until manual
  `umount -f -l`. Worse pathology than what we have.
- **Just `x-systemd.mount-timeout=300s`.** Hides the bug for longer
  without addressing root cause. Will eventually be insufficient as
  tailscale evolves further.
- **Custom `tailscale-online.target` driven by `tailscale status`
  polling.** Functionally equivalent to `tailscale wait` but more code.
  Predates upstream's CLI fix; obsolete.

## Files

- `modules/nixos/services/tailscale/default.nix` — defines
  `tailscale-wait.service` once for the fleet.
- `modules/nixos/services/mounts/external.nix` — fstab options for doc1's
  /mnt/mum mount.
- `modules/nixos/services/kopia.nix` — fstab options for doc2's
  /mnt/mum mount (defined inline alongside the kopia-mum instance).

## When to revisit

- If Tailscale upstream closes [#11504](https://github.com/tailscale/tailscale/issues/11504)
  and ships a real `READY=1`-after-tunnel-bindable, the `tailscale-wait`
  oneshot becomes redundant. We can drop it then.
- If we add another NFS-over-tailnet mount, route it through
  `tailscale-wait.service` the same way. Don't duplicate the race.

## Sources

- [tailscale/tailscale#11504 — readiness reported before bindable](https://github.com/tailscale/tailscale/issues/11504)
- [`tailscale wait` reference](https://tailscale.com/docs/reference/tailscale-cli)
- [systemd.mount(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)
- [systemd.unit(5) — `Requires=` semantics](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)
