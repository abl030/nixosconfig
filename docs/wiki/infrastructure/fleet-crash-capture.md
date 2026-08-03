# Fleet crash capture (netconsole standard, kdump opt-in)

**Date researched:** 2026-07-25; revised 2026-08-03 after the second doc2 panic
**Status:** netconsole fleet-wide; doc1 and doc2 kdump-enabled; doc2 uses a dedicated source-filtered prom receiver
**Module:** `modules/nixos/services/crash-capture.nix` (`homelab.crashCapture.*`)
**Issue:** [#51](https://git.ablz.au/abl030/nixosconfig/issues/51)
**Related:** [doc2-kernel-panic-2026-07-22.md](doc2-kernel-panic-2026-07-22.md),
[virtiofs-nested-reexport-stale-pins.md](virtiofs-nested-reexport-stale-pins.md)

## Why

doc1 kernel-panicked on 2026-07-24 and **the faulting frames were lost**. EFI pstore truncated the
middle chunks, and doc1 had no off-box console, so the single artifact that would have closed the RCA
never existed. doc2 has had a netconsole sender since its own 2026-07-22 panic; every other host was
mute. The asymmetry was the whole problem — the host that crashed was the one not being listened to.

## The two tiers, and why they are separate

| | netconsole | kdump |
|---|---|---|
| Captures | oops/panic **text**, sysrq dumps | full `/proc/vmcore` memory image |
| RAM cost | none | `reservedMemory`, permanently unavailable |
| Disk cost | none | up to RAM size, gzipped |
| Availability cost | none | `panic_on_oops=1` turns survivable oopses into reboots |
| Default | **on** (non-container hosts) | **off** |

netconsole is the fleet standard because it is free and it captures the thing that was actually
missing. kdump is opt-in because its costs are real and only pay off if you intend to run `crash(8)`
against the image.

## The kdump trap

`boot.crashDump.enable = true` **is not sufficient on its own.** Stock NixOS boots the capture kernel
into systemd rescue and *leaves it there* — the vmcore sits at `/proc/vmcore` waiting for a human.
Unattended that is strictly worse than the existing `panic=30`: a panicked host stays down instead of
rebooting in 30 seconds.

`homelab.crashCapture.kdump` therefore adds a `crash-capture-save-vmcore` service
(`WantedBy=rescue.target emergency.target`, `ConditionPathExists=/proc/vmcore`) which writes the kernel
log first, preallocates `minimumFreeGiB` as a real non-sparse reserve, then streams a gzip-compressed
vmcore. A raw-RAM-size preflight is deliberately not used: doc2 has 30 GB RAM but only 55 GB free,
while zero and free pages compress well. ENOSPC cannot consume the held reserve; interrupted streams are
retained with a `.partial` suffix and never presented as completed dumps. Compression has a 15-minute
deadline, after which the script records the reason, releases the reserve, syncs and reboots. Each dump
also retains the exact unstripped `vmlinux`, module closure and kernel identity/hash context required for
analysis. A 20-minute whole-service deadline, bounded TERM/KILL escalation and `FailureAction=reboot-force`
prevent the capture kernel remaining in rescue mode after any script, storage or compression failure.
Retention selects the newest `keepDumps` crash timestamps and deletes every older generation as a set,
so completed, partial and skipped artifacts cannot each consume an independent quota.

`makedumpfile` is **not packaged in nixpkgs** (checked 2026-07-25), so dumps cannot be filtered down to
non-free pages; a raw gzip of guest RAM is the best available. This is why the free-space guard exists
and why `reservedMemory` defaults to a conservative `256M`.

## Where it cannot work

LXC containers and WSL share the host kernel: there is no guest kernel log to stream and no kexec to
perform. `caddy` and `igpu` are Proxmox LXCs (`configuration-lxc.nix` → `boot.isContainer`), and `wsl`
sets `wsl.enable`. The module auto-disables on these and **asserts** if either tier is forced on, rather
than silently doing nothing. Capture crashes for those hosts on their kernel owner (prom, or Windows).

Verified 2026-07-25 — unit present on `proxmox-vm`, `doc2`, `servarr`; absent on `igpu`, `caddy`, `wsl`.

## The loglevel gotcha (cost me an hour; read this before declaring netconsole broken)

The dedicated prom receiver showing no packets on a healthy system is **normal**, not a fault. The fleet boots
`loglevel=4`, so `console_loglevel = 4` and only messages with level < 4 (emerg/alert/crit/err) reach
*any* console, netconsole included. Routine INFO chatter is filtered by design, and a healthy quiet
kernel sends nothing for weeks.

Test delivery properly — an INFO-level marker will be silently dropped and prove nothing:

```sh
# on the sending host — <2> is KERN_CRIT, which passes the loglevel=4 filter
ssh doc2 "echo '<2>netconsole-test-$(date +%s)' | sudo tee /dev/kmsg"
# on prom
ssh root@prom 'tail -n 5 /var/log/doc2-netconsole/kernel.log'
```

The old UDP/6666 kernel sender was verified with this method on 2026-07-25. The dedicated UDP/6667
route, firewall, receiver filtering and persistence were verified with a harmless userspace datagram on
2026-08-03; the boot-time kernel sender still requires the documented post-deployment reboot and
KERN_CRIT acceptance check.

What this means for crash capture: **oops and panic output is EMERG/ALERT/CRIT and is carried.** So is
sysrq output — `__handle_sysrq()` raises `console_loglevel` to default for the duration of the handler,
which is why the `doc2-recovery` sysrq task dumps also reach prom.

## Design notes

- **The collector MAC is pinned, deliberately.** At panic time the kernel is in atomic context and
  cannot ARP; relying on a live neighbour entry loses exactly the messages this exists to capture.
- **The source interface is discovered at start**, via `ip -4 route get <collector>`, so hosts with
  different NIC names need no per-host configuration. doc2's old sender hardcoded `ens18`.
- **`oopsOnly` is left off** so sysrq task dumps travel too, not just oopses.
- **doc2 uses prom UDP/6667 exclusively.** UDP/6666 remains the issue-51 lab listener. The prior shared
  port silently mixed doc2's 2026-08-03 panic into `/var/log/vm951-netconsole.log` under the wrong
  production label. `doc2-netconsole-prom-sync.service` on doc1 installs a source-filtered, hardened
  receiver on prom, which timestamps and prefixes every logical line into
  `/var/log/doc2-netconsole/kernel.log`, records its effective receive buffer and kernel-reported UDP
  queue drops, and rejects sources other than doc2's two LAN addresses. The existing source-restricted
  Proxmox firewall rule is still required and is checked by the sync service.
- **Source filtering is attribution, not authentication.** Plain UDP permits same-LAN spoofing; the
  receiver allow-list and Proxmox firewall prevent accidental cross-talk but do not cryptographically
  authenticate the sender.
- **The receiver is independent of doc2 and doc1 at crash time.** prom owns the process, log and disk.
  doc1 only reconciles the receiver files during activation/boot using its existing scoped prom key.
- This dedicated labelled receiver is doc2-specific; other fleet senders retain their separately
  configured collectors. Kdump remains an independent second evidence tier.

Prom's non-NixOS firewall invariant is persisted in `/etc/pve/nodes/prom/host.fw`:

```text
IN ACCEPT -source 192.168.1.35,192.168.1.36 -p udp -dport 6667 -log nolog
```

Keep the old doc2 UDP/6666 rule only through sender migration; remove it after live UDP/6667 acceptance.
The issue-51 VM951 UDP/6666 rules and receiver remain independent.

## Enabling kdump on a host

```nix
homelab.crashCapture.kdump = {
  enable = true;
  reservedMemory = "256M";  # raise only if the capture kernel fails to boot
};
```

Then confirm after reboot — a failed reservation is silent apart from dmesg:

```sh
cat /sys/kernel/kexec_crash_loaded   # must be 1
dmesg | grep -i crashkernel          # must not say "reservation failed"
```

Do **not** enable on `servarr` at the default size without thought: it has 3 GB of RAM, so 256M is
~8% of the host.

## 2026-08-03 doc2 recurrence and capture corrections

The recurrence proved that the sender worked but the collector topology did not. doc2 panicked at
`15:53:31.529 AWST` with a recursive page fault/double fault at the same unrelocated
`asm_exc_page_fault` address as the 2026-07-22 panic. Its packets reached prom only because the
issue-51 lab's broad `vm951-netconsole-recv` socat process happened to own UDP/6666. The panic was
therefore found later in `/var/log/vm951-netconsole.log`, mixed with multiple lab guests and lacking
reliable production source attribution. The first fault's stack had already been destroyed by the double fault.

The recovery watchdog separately reached its sustained-failure threshold, but `for key in w t`
overwrote the SSH identity variable. Every later prom command used `ssh -i w` or `ssh -i t`, so SysRq,
post-failure evidence and `qm reset` all failed. The corrected watchdog:

1. keeps `ssh_key` immutable and uses `sysrq_key` for trigger iteration;
2. captures QMP status, all-vCPU registers, Proxmox RRD, QEMU host-thread stacks and the dedicated
   netconsole tail without guest cooperation;
3. treats sustained TCP/22 loss on both doc2 LAN addresses with live QGA as a capture-only condition,
   collecting SysRq task stacks but never resetting;
4. resets only after both TCP/22 paths and QGA are unavailable for 25 consecutive one-minute checks, safely
   outlasting the crash-dump service's 15-minute compression deadline plus its five-minute margin, then
   rechecks both paths, VM uptime/state, and the receiver/firewall after evidence collection so recovery
   or a VM transition cancels the reset;
5. resets its counters after any observation gap, so stale evidence cannot authorize a later reset; and
6. allows ten minutes for the expanded evidence transaction before systemd times it out.

Incident bundles live under `/var/lib/doc2-recovery/incidents/<UTC>/` on doc1. The watchdog retains the
newest 20 directories; archive any case that must be kept longer before further experiments.

doc2 now reserves 512 MiB for kdump, sets `panic_on_oops=1` through the crash-capture module, and sets
`panic_print=63`. This is intentional: the next first oops should enter the capture kernel before a
secondary exception destroys its stack. After the required reboot, acceptance is:

```sh
ssh doc2 'cat /sys/kernel/kexec_crash_loaded; sysctl kernel.panic_on_oops kernel.panic_print'
# Expected: 1, 1, 63

ssh root@prom 'systemctl is-active doc2-netconsole-receiver; ss -lunp | grep :6667'
ssh doc2 "echo '<2>doc2-netconsole-acceptance-$(date +%s)' | sudo tee /dev/kmsg"
ssh root@prom 'tail -n 5 /var/log/doc2-netconsole/kernel.log'
```

A deliberate SysRq crash is not part of routine deployment. If explicitly authorized later, it is the
only end-to-end proof of crash-kernel boot, vmcore persistence and automatic return to service.

## When to revisit

If a host panics and the netconsole capture still does not name the faulting function, that is the
signal to enable kdump on that host specifically — not fleet-wide.
