# systemd-nspawn: FailureAction/OnFailure → kernel pidns wedge

**Status:** UPSTREAM BUG (kernel + systemd-nspawn interaction). Avoid the trigger; document the recovery.

**Date researched:** 2026-05-20. Hit during [#250](https://github.com/abl030/nixosconfig/issues/250) deliberate-failure testing of the new `mk-pg-container` ownership invariant.

## TL;DR

Using `FailureAction=exit-force` or `OnFailure=poweroff.target` on a unit inside an nspawn container, with the intent of failing the OUTER `container@<name>.service` so Kuma can see it, **reliably wedges the container's PID namespace at kernel level**. A `[systemd-shutdow]` process gets stuck in uninterruptible D-state in `zap_pid_ns_processes`, holding the pidns and the machinectl registration. Subsequent `systemctl start` fails with `Failed to register machine: Machine '<name>' already exists`. Only a host reboot recovers.

**Don't use these mechanisms on nspawn-internal units.** Failures need to surface via a different path — see "Alternatives" below.

## Symptoms (in this order)

1. The triggering inner unit fails (e.g. our `postgresql-setup.service` with the ownership invariant).
2. Inner systemd starts shutdown (`Sending SIGTERM to remaining processes`...).
3. The outer `container@<name>.service` either goes `inactive (dead)` (poweroff path) or briefly `failed (exit-code)` (exit-force path).
4. **The container does not actually stop cleanly.** A `[systemd-shutdow]` process stays.
5. `machinectl list` shows the container with `-` for OS/VERSION/ADDRESSES.
6. `machinectl terminate <name>` returns `No such process`.
7. `machinectl status <name>` shows `Leader: <pid> (systemd-shutdow)` for a process that's been alive for the whole wedge duration.
8. `systemctl start container@<name>.service` → `Failed to register machine: '<name>' already exists` → `Parent died too early`.
9. `kill -9 <pid>` on the leader has no effect — the process is in D-state.
10. Restarting `systemd-machined` does not clear it.

## Root cause

Kernel stack trace of the stuck process (root only, `cat /proc/<pid>/stack`):

```
[<0>] zap_pid_ns_processes+0x11b/0x190
[<0>] do_exit+0xa7a/0xac0
[<0>] reboot_pid_ns+0x81/0x90
[<0>] __do_sys_reboot+0xa8/0x240
[<0>] do_syscall_64+0xd6/0x7c0
[<0>] entry_SYSCALL_64_after_hwframe+0x77/0x7f
```

`zap_pid_ns_processes` is the kernel function that tears down a PID namespace when its init process exits. It waits for every process inside the namespace to be reaped. Something inside isn't reapable — likely a process stuck in another D-state, or with an orphaned child whose parent has already detached. The kernel can't proceed; the pidns can't be freed; the namespace ID stays allocated; machinectl's lookup still resolves the (dead) container.

This is a known kernel pathology — there are kernel commits over the years tweaking `zap_pid_ns_processes` to be more robust against unreapable children, but the failure mode is not fully eliminated.

`systemd-nspawn` itself can't recover: it has no way to force-free a pidns that the kernel won't release.

## Where we hit this

In `modules/nixos/lib/mk-pg-container.nix`, trying to make the schema-ownership invariant's failure propagate from the inner `postgresql-setup.service` out to the outer `container@<svc>-db.service` for Kuma alerting. Two attempts, both wedged:

- `unitConfig.OnFailure = ["poweroff.target"]` → inner systemd starts `poweroff.target` cleanly, exits 0, container wedges.
- `unitConfig.FailureAction = "exit-force"` + `unitConfig.FailureActionExitStatus = 1` → inner PID 1 attempts to exit, container wedges.

Both reverted in commit `630b2788`. The invariant code itself stays (it fires loudly in the inner journal); only the outer-propagation machinery is removed.

The `jellystat-db` container had been carrying the same wedge from a prior incident — it was sitting `failed (start-limit-hit)` for ~2 days before this session and we'd been ignoring it. Same kernel stack. After our deploy the host had two wedged containers (immich-db + jellystat-db) and we rebooted doc2 to recover.

## Recovery

**Only a host reboot clears the wedge.** Nothing in userland — `systemctl`, `machinectl`, `kill -9`, `systemd-machined` restart — can free the held pidns.

```sh
sudo systemctl reboot
# ~60-90 seconds of fleet outage for everything on the host
```

After reboot, all nspawn containers come back cleanly. machinectl registrations are recreated fresh.

## Alternatives — how to actually alert on inner unit failure

Don't try to flip the outer container state. Instead:

1. **Loki alert on inner journal patterns.** `alloy` ships the inner systemd journal to Loki including the inner unit failure events. A Grafana/Mimir alert on `unit=postgresql-setup.service` with `result=exit-code` (or matching `schema-ownership invariant violated`) → Gotify push. This is the path tracked in [#253](https://github.com/abl030/nixosconfig/issues/253) (per-service `errorPatterns`).

2. **External health probe.** A systemd timer on the host that runs `systemd-run --machine=<name> systemctl is-failed <inner-unit>` and reports to a Kuma push monitor. Doesn't require flipping the outer service.

3. **`RequiredBy=multi-user.target` is safe.** Promoting the unit to be required-by (vs wanted-by) the inner multi-user.target makes the inner target fail to reach when the unit fails. That itself is harmless — multi-user just stays inactive. It only tips into pidns-wedge territory if you ALSO try to exit/poweroff from there.

## Detection (forensic only)

If you suspect a wedged pidns:

```sh
sudo machinectl list                    # container shown with `-` fields
sudo machinectl status <name>           # Leader is a systemd-shutdow pid
ps -p <pid> -o stat,wchan               # state D, in some kernel sleep
sudo cat /proc/<pid>/stack | head       # zap_pid_ns_processes near top of stack
```

If you see this, the container is unrecoverable without a host reboot. Don't waste time on `kill -9`, machinectl-terminate, machined-restart — they all fail silently.

## When to revisit

- Linux kernel ≥ 6.20-ish if `zap_pid_ns_processes` gets a stronger "abandoned child" reaper.
- systemd-nspawn change that drains inner processes before the inner systemd can exit (i.e. nspawn-driven shutdown vs inner-init-driven).
- Migration off nspawn for service DBs entirely. We chose nspawn for blast-radius reasons (see `.claude/rules/nixos-service-modules.md`); a future move to e.g. dedicated VMs would avoid this whole class.

## Related

- [`docs/wiki/services/immich-asset-edit-audit-incident.md`](../services/immich-asset-edit-audit-incident.md) — the incident where we discovered this trying to ship a schema-ownership invariant alert
- [issue #250](https://github.com/abl030/nixosconfig/issues/250) — the invariant + incident postmortem
- [issue #253](https://github.com/abl030/nixosconfig/issues/253) — Loki errorPatterns alerts (the path we use now instead of outer-service-state)
- `modules/nixos/lib/mk-pg-container.nix` — anti-pattern call-out near the `postgresql-setup` config block
