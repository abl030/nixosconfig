# NFS over Tailscale: mount cascade pathology

**Date researched:** 2026-05-11
**Status:** Active workaround in place; root cause is upstream Tailscale bug.
**Affects:** any NFS (or other connection-oriented network mount) whose server is only reachable via the tailnet.
**Issue / fix:** [PR #243](https://github.com/abl030/nixosconfig/pull/243) — incident, design discussion, code-review thread, and rollout all live in the PR.

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

3. **Fast-fail on real outages.** Add `x-systemd.mount-timeout=30s` so a
   genuine outage surfaces in 30s instead of stalling 90s. Add `nofail`
   so the *boot target* doesn't wait for the mount and downstream
   `remote-fs.target` consumers aren't blocked — but note that `nofail`
   does **not** prevent `switch-to-configuration-ng` from returning
   exit 4 on a failed mount unit. The new Rust replacement scans all
   unit states regardless of `nofail` (verified against
   `pkgs/by-name/sw/switch-to-configuration-ng/src/main.rs:2470-2531`
   in nixpkgs — zero references to `nofail` anywhere). The design
   intent here is: when `mum` is genuinely unreachable for >30s, the
   rebuild **should** fail and page us — that's correct behavior, not
   a bug. The fix this PR delivers is the cascade-readiness gate
   (#1, #2), which eliminates the spurious race that caused the
   2026-05-11 failure. Genuine outages still surface; the spurious
   race no longer does.

## Scope of the readiness gate (and what NOT to add)

`tailscale-wait.service` gates on **local interface bindability only** —
`tailscale wait` blocks until tailscale0 is up and an IP is assigned. It
does NOT verify the remote peer (100.100.237.21, mum's Synology) is
reachable. **This is intentional and correct.**

Don't be tempted to add a peer-reachability check (e.g.
`ExecStartPost=tailscale ping 100.100.237.21` or similar). Three reasons:

1. **Point-in-time peer reachability tells us nothing useful.** The
   rebuild fires at 03:00; the backup fires at 04:00 (per kopia's
   internal scheduler). Even a successful peer ping at rebuild time
   doesn't predict reachability an hour later when kopia actually runs.
   Adding a peer gate would just create a false sense of security.
2. **The mount itself IS the peer-reachability signal.** When
   `mnt-mum.mount` succeeds, that's empirical proof the peer was
   reachable. Adding a separate `tailscale ping` before mount.nfs is
   redundant — and worse, decouples the check from the operation,
   widening the race window.
3. **Bloats `tailscale-wait` with backup-specific logic.** The unit's
   job is general tunnel readiness for any consumer. Backup-specific
   peer checks belong in kopia's own monitoring (the existing
   `errorCount > 0` JSON-query monitor catches snapshot failures
   regardless of root cause).

The readiness gate's correct scope: ensure the LOCAL tunnel is up before
mount.nfs runs. Anything beyond that is the mount's job — and `nofail`
+ `mount-timeout=30s` + s-t-c-ng's failed-unit scan make a genuine peer
outage page us anyway.

## Operational data: mount-duration distribution

30-day Loki window (2026-04-11 → 2026-05-11), both `/mnt/mum`-mounting
hosts (`doc2`, `proxmox-vm`). Paired `Mounting /mnt/mum` log lines with
the subsequent `Mounted` or `timed out`:

| Outcome | Count | Duration |
|---|---|---|
| Success | 12 | min 0.47s · p50 0.60s · p90 3.26s · p99 6.10s · max 6.10s |
| Timeout (90s ceiling) | 10 | clustered at 89-91s (systemd's default `mount-timeout=90s`) |

The distribution is bimodal — either the mount completes in <10s or it
stalls the full 90s. **Zero observed successful mounts in the 10s-90s
range.** That falsifies the theoretical "cold NFSv4 over DERP takes
20-40s" concern for our specific topology (mum's Synology + doc2 + doc1
are all residential-direct, no DERP-relay paths in the normal case).

**`x-systemd.mount-timeout=30s` is therefore safe**: ~5x headroom over
the observed p99 successful mount, while still tight enough to fail
fast if the tunnel is genuinely broken.

If we ever start seeing successful mounts in the 10s-30s range in Loki
(query `{host=~"doc2|proxmox-vm"} |= "/mnt/mum" |~ "Mounting|Mounted"`),
that's the signal to revisit this number. Until then, the chosen
timeout is grounded in actual data, not theoretical headroom.

The 10 timeouts in 30 days were almost all on `doc2`, clustered around
deployment / cascade-restart events — exactly the failure pattern this
PR's readiness gate fixes. Expect timeout counts to drop sharply after
this PR lands.

## Empirical: what an unsatisfied automount actually returns

A natural worry when designing this fix: if the mount fails but
`mnt-mum.automount` remains active, what does userspace see when it
accesses `/mnt/mum`? Two plausible kernel behaviours:

- **(a) Empty trigger directory** — the automount stub is just an empty
  directory; reads succeed and return no entries; writes land on the
  underlying filesystem hidden under the (failed) mountpoint.
- **(b) `ELOOP` / "Too many levels of symbolic links"** — the kernel
  refuses every access until the automount handler can satisfy the
  mount.

This matters because (a) would allow kopia to silently snapshot an empty
directory and overwrite a real backup chain. (b) means kopia gets a
real I/O error → `errorCount > 0` → existing monitor pages.

**Tested empirically on doc2 (2026-05-11) — the answer is (b).** In a
mount namespace where `/mnt/mum` was umounted (but the automount stub
remained), every operation returned `ELOOP`:

```
$ ls -la /mnt/mum
ls: cannot open directory '/mnt/mum': Too many levels of symbolic links
$ echo test > /mnt/mum/.canary
bash: /mnt/mum/.canary: Too many levels of symbolic links
$ test -f /mnt/mum/kopia.repository.f
(returns false)
```

This generalises: any consumer of an NFS-over-Tailscale automount sees
a hard `ELOOP` on access when the underlying mount cannot be satisfied.
You cannot accidentally write to "the empty mountpoint underneath" —
the autofs handler holds an exclusive lock until it succeeds or returns
the error.

The corollary for backup integrity: as long as the underlying tool
treats `ELOOP` as a real error (kopia does — it surfaces as
`errorCount > 0`), the silent-empty-snapshot failure mode is mechanically
impossible on this stack.

## Related: LAN-vs-Tailscale routing for tower NFS

The fleet also runs NFS to `tower` (Unraid) on most at-home hosts.
That mount has the same readiness-gap pathology when accessed over
Tailscale, so it now uses the same `tailscale-wait` gate (#7 of this
PR's code-review punch list).

But there's a routing question that's separate from the readiness
gate: should at-home hosts reach tower via Tailscale, or via tower's
LAN IP directly?

**Default: LAN.** `homelab.mounts.nfs.server` defaults to tower's LAN
IP (`192.168.1.2`). Every NFS RPC stays on the LAN, no Tailscale
dependency. Fewer points of failure and zero readiness-gap risk for
at-home hosts (epi, doc2 if it ever needed tower data, etc.).

**Opt-in: `external = true`** for hosts that *aren't* on the home LAN
— currently just framework when on the road. That flips the server
address to the `tower` MagicDNS name and pulls in the tailscale-wait
dependency. The flag exists to make the routing choice explicit and
host-local.

This split was originally designed in but got lost in the
2026-01-19 mounts refactor (default became `"tower"` for every host).
Restored 2026-05-11. If you find a future change defaulting to the
Tailscale path again, it's a regression — keep the LAN default and
gate Tailscale behind an explicit opt-in.

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
- **Peer-reachability check in `tailscale-wait`** (e.g.
  `ExecStartPost=tailscale ping 100.100.237.21`). Rejected — see
  "Scope of the readiness gate" above.

## Files

- `modules/nixos/services/tailscale/default.nix` — defines
  `tailscale-wait.service` once for the fleet. The canonical readiness
  primitive any NFS-over-tailnet mount should depend on.
- `modules/nixos/services/mounts/mum-nfs.nix` — `/mnt/mum` fstab
  options. Single definition shared by doc1 (which sets
  `homelab.mounts.mumNfs.enable = true` directly) and doc2 (where
  `kopia.nix` sets it via `lib.mkIf needsMumMount`).
- `modules/nixos/services/mounts/nfs.nix` — `/mnt/data` and
  `/mnt/appdata` fstab options. Uses the same `tailscale-wait` gate
  when `external = true` or `server = "tower"`. See the "LAN-vs-Tailscale
  routing" section above for the routing decision.
- `modules/nixos/services/kopia.nix` — opts into mum-nfs.nix when
  `repositoryMounts` references `/mnt/mum`. Note: `/mnt/mum` is the
  kopia *repository destination*, not a source path — kopia reads
  `kopia.repository.f` / writes blob packs there. The instance's
  `sources` field is the **read-only** input data being backed up
  (currently `/mnt/data` from tower). Confusing the two is what made
  the original P0 review finding plausible-looking but mechanically
  wrong.

## When to revisit

- If Tailscale upstream closes [#11504](https://github.com/tailscale/tailscale/issues/11504)
  and ships a real `READY=1`-after-tunnel-bindable, the `tailscale-wait`
  oneshot becomes redundant. We can drop it then.
- If we add another NFS-over-tailnet mount, route it through
  `tailscale-wait.service` the same way. Don't duplicate the race.
- If Loki starts showing successful mount durations in the 10s–30s
  range (`{host=~"doc2|proxmox-vm"} |= "/mnt/mum" |~ "Mounting|Mounted"`),
  re-evaluate `x-systemd.mount-timeout=30s`. Current data shows p99
  at 6.10s; new evidence above that ceiling would change the calculus.
- If kopia ever introduces "snapshot empty source as zero-byte entry"
  semantics that bypass `errorCount`, the "Empirical: ELOOP" section
  no longer protects us — add an active `totalFileSize > N` monitor.
- If a future refactor changes the `homelab.mounts.nfs.server` default
  away from the LAN IP, it's almost certainly a regression. See the
  "LAN-vs-Tailscale routing" section.

## Sources

- [tailscale/tailscale#11504 — readiness reported before bindable](https://github.com/tailscale/tailscale/issues/11504)
- [`tailscale wait` reference](https://tailscale.com/docs/reference/tailscale-cli)
- [systemd.mount(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)
- [systemd.unit(5) — `Requires=` semantics](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)
