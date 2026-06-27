# prom rpool SATA instability — RESOLVED: one faulty drive

**Status:** ✅ **RESOLVED 2026-06-27.** Root cause was a **single faulty SanDisk SSD (`24370L802287`)** dropping its SATA link under sustained load. *Not* cables, ports, the controller, PCIe/power-states, NCQ, or LPM — those were investigated and excluded. Fixed by removing the drive and rebuilding the mirror. Current host config: [prom-hypervisor.md](prom-hypervisor.md). Original ticket: GitHub **#276**.

## What it was
prom (the Proxmox hypervisor) hard-froze — total lockup, nothing logged (`/sys/fs/pstore` empty, journal truncated, no MCE) — whenever its rpool boot mirror saw **sustained SATA I/O**: a `zpool scrub`, a resilver, or even the boot-time pool-import write burst. Over ~3 weeks it escalated from kernel log storms → ungraceful reboots → full host hangs.

## Root cause (the actual one)
One of the two SanDisk SSD PLUS 240GB drives in the boot mirror — serial **`24370L802287`**, confusingly the one originally labelled the healthy *"survivor"* — has a **failing SATA interface**. Under sustained read load its link throws **8b/10b decode errors**:
```
ataX: SError: { RecovComm HostInt PHYRdyChg PHYInt CommWake 10B8B DevExch }
ataX.00: exception Emask 0x50 ... frozen      (0x50 = host-bus-fatal)
ataX: hard resetting link → SATA link up 1.5 Gbps   (degraded from 6.0)
```
i.e. the drive **drops in and out of SATA under load**. With **NCQ enabled**, a link reset mid-queue deadlocked the AHCI controller → **total host freeze**, and corrupted in-flight reads on the *other* controller (the "cross-controller corruption" that sent us chasing the chipset/PCIe/power-state for a while — a red herring).

## The test that proved it
Disabling NCQ (`queue_depth=1`) stopped the fault from freezing the host and turned it into a *contained, recoverable* link-reset storm — which **unmasked the source**. The storm then **followed drive `…802287` across a brand-new SATA cable AND a different SATA port AND a forced 1.5 Gb/s link**, on two separate runs, while the *other* SanDisk (`…800457`) and a new ADATA SSD ran the identical load flawlessly. **A fault that follows one specific drive across new cable + new port = the drive itself.**

## Ruled out along the way (don't re-chase these)
All investigated and **excluded** — none was the cause:
- **SATA data cables** — replaced all; fault stayed with the drive (SMART showed 0 CRC).
- **SATA ports** — moved drives to different ports; fault followed the drive.
- **Power** — gave the replacement its own PSU lead; irrelevant to the (drive) fault.
- **AMD chipset SATA controller / PCIe uplink** — the cross-controller corruption was an *NCQ-deadlock artifact*; healthy drives share the same controller and are fine.
- **PCIe ASPM** — already disabled on the SATA controllers by BIOS.
- **SATA LPM / DIPM (`med_power_with_dipm`)** — disabled it; box still froze. (A genuine hang-trigger *class* on AMD SATA, worth keeping off — but not *this* fault.)
- **AMD-gen5 AHCI NCQ-timeout kernel regression (kernel.org #220693)** — our kernel was already past the fix and the signature was the worse host-bus-fatal variant; noncq helped only by *containing* the drive fault.
- **Memory / Infinity-Fabric** — MemTest clean; NVMe on the same board flawless throughout.
- **The originally-condemned drive `…800457`** — its earlier #276 symptoms (IDENTIFY failures, link drops) were the *old* cabling; on fresh wiring it ran a full resilver **and** scrub clean. A wiring victim, not faulty.

## The fix (2026-06-27)
1. Removed the faulty **`…802287`**.
2. Rebuilt the mirror as **`…800457` (SanDisk survivor) + ADATA SU650 256GB** — `zpool replace`, resilvered clean. Rebuilt a managed ESP on both drives.
3. Kept a conservative, reliability-first SATA config as defence-in-depth (negligible cost on a boot pool that does almost nothing): **1.5 Gb/s link cap · NCQ off · LPM off**. Full flag list + rationale: [prom-hypervisor.md](prom-hypervisor.md).

**Validation:** a full resilver (22 GB) **and** a full scrub both completed at 1.5 Gb/s with **0 ata errors and zero link flapping** — the exact sustained load that froze the host every time before.

## Lessons
- A drive can be **SMART-clean and fine at idle yet have a failing SATA PHY that only shows under sustained load** — and it can be the drive you *least* suspect.
- **NCQ-off (`queue_depth=1`) is a powerful diagnostic**: it converts a controller-deadlocking link fault into a contained, attributable storm.
- A fault that **follows the drive across new cable + new port** is the drive — run that test early instead of theorising.
- On AMD chipset SATA, set `ahci.mobile_lpm_policy=1` regardless — the `med_power_with_dipm` default is a known hang trigger.
- Don't `udevadm trigger` a whole disk while a SATA link is flapping (forces a re-scan that reads the bad drive and wedges rpool I/O). And on long doc1 sessions, a stale forwarded ssh-agent can masquerade as a wedged host — bypass with `SSH_AUTH_SOCK= ssh -i ~/.ssh/id_ed25519`.
