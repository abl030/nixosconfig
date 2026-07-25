# Fleet crash capture (netconsole standard, kdump opt-in)

**Date researched:** 2026-07-25
**Status:** netconsole generalised fleet-wide; kdump implemented but opt-in and not yet enabled anywhere
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
log first (small, high value, survives a full disk), then the gzipped vmcore **only if it fits in half
the free space**, prunes to `keepDumps`, and reboots. Availability is preserved.

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

doc1's `doc2-netconsole.socket` reporting `IP: 0B in` is **normal**, not a fault. The fleet boots
`loglevel=4`, so `console_loglevel = 4` and only messages with level < 4 (emerg/alert/crit/err) reach
*any* console, netconsole included. Routine INFO chatter is filtered by design, and a healthy quiet
kernel sends nothing for weeks.

Test delivery properly — an INFO-level marker will be silently dropped and prove nothing:

```sh
# on the sending host — <2> is KERN_CRIT, which passes the loglevel=4 filter
ssh doc2 "echo '<2>netconsole-test-$(date +%s)' | sudo tee /dev/kmsg"
# on the collector (doc1)
sudo journalctl -t doc2-netconsole --since '-2 min'
```

Verified working end-to-end on 2026-07-25: the crit marker arrived; an INFO marker sent moments earlier
did not, and `tcpdump -i ens18 'udp port 6666'` showed zero packets for it.

What this means for crash capture: **oops and panic output is EMERG/ALERT/CRIT and is carried.** So is
sysrq output — `__handle_sysrq()` raises `console_loglevel` to default for the duration of the handler,
which is why the `doc2-recovery` sysrq task dumps also reach doc1.

## Design notes

- **The collector MAC is pinned, deliberately.** At panic time the kernel is in atomic context and
  cannot ARP; relying on a live neighbour entry loses exactly the messages this exists to capture.
- **The source interface is discovered at start**, via `ip -4 route get <collector>`, so hosts with
  different NIC names need no per-host configuration. doc2's old sender hardcoded `ens18`.
- **`oopsOnly` is left off** so sysrq task dumps travel too, not just oopses.
- doc1 is the collector and correctly starts no sender for itself (the script detects that its source
  address is the collector address and exits cleanly).

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

## When to revisit

If a host panics and the netconsole capture still does not name the faulting function, that is the
signal to enable kdump on that host specifically — not fleet-wide.
