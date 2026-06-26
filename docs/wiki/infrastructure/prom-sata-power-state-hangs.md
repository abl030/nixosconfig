# prom: hard hangs / power-state panics under SATA I/O (UNRESOLVED)

**Date:** 2026-06-26 · **Status:** 🔴 **ongoing / root cause not fully fixed.** prom hard-freezes (and once kernel-panicked with on-screen *power-state* errors) under heavy SATA I/O. Disabling SATA link power management did **not** stop it. Lead now = platform/AGESA power-state, with a BIOS update + "move boot pool off chipset SATA" as the candidate cures.
**Related:** GitHub **#276** (originally filed as "dodgy boot SSD") · [prom-rpool-backup-restore.md](prom-rpool-backup-restore.md) (the off-box backup + restore runbook — **the data is safe**).

> **Headline:** what looked like a dying SanDisk boot SSD is really a **host-level power-state instability** on this AM5 / AMD 600-series-chipset board, triggered by SATA write/scrub load. The drive-swapping chased a symptom. Data was never at risk (pool clean + verified tower backup).

---

## Current state (leave it alone)
- prom is **up and stable at idle** on a clean 2-way ZFS mirror: **`…802287` (survivor) + `…800457`** (the original "failing" drive — it currently works). Pool `rpool` ONLINE, "No known data errors."
- The replacement **ADATA SU650 256GB is NOT installed** (set aside as a spare).
- **Do NOT**: pull a drive, run `zpool scrub`, or attempt the mirror rebuild — every load/boot experiment re-triggers the hang and erodes the drives. Get the platform stable *first*.

## Hardware
- Board **ASRock X870E Taichi Lite**, BIOS AMI **3.50** (2025-09-18, AGESA ComboAM5 **1.2.0.3g**). Current available: **4.41** (AGESA **1.3.0.1b**).
- CPU **AMD Ryzen 9 9950X** (Granite Ridge, Zen 5, AM5). RAM 128 GB DDR5-5600 (2×64 GB Micron). **MemTest: ~3 days clean at purchase** → memory largely ruled out.
- OS Proxmox VE 9.2.3, kernel **7.0.12-1-pve**.
- Boot pool `rpool` = ZFS mirror of **2× SanDisk SSD PLUS 240GB fw 42077100** (Marvell, DRAM-less budget SATA). Replacement tried: **ADATA SU650 256 GB** (also DRAM-less) — behaved identically.
- The two SATA controllers are **AMD 600-series chipset SATA `[1022:43f6]`** at PCI `13:00.0` and `15:00.0`, each **behind the chipset's internal PCIe switches** (`[1022:43f4/43f5]`). NVMe (3× Samsung 990 PRO + 1× Crucial T700) is on CPU/other lanes and is **rock-solid**.

## Symptoms
- **Hard host lockups** (total freeze — ICMP/SSH/UI all dead) and, once, a **kernel panic with "power state" errors visible on the monitor**, struck:
  - ~1–2 s into early userspace at the first **writes to rpool** (`systemd-journal-flush`), and
  - within ~2 s of a ZFS **resilver/scrub** starting heavy SATA I/O.
- **Nothing is logged**: `/sys/fs/pstore` empty every time (no panic dump), no MCE/EDAC, no ata error/ZFS error in the persistent journal — the on-disk journal just stops mid-line (storage path hangs → can't write the journal).
- When network-shipped logs caught the tail: a write to a SSD on **controller B (15:00.0)** produced **ZFS checksum errors on the survivor SSD on controller A (13:00.0)** + `ata.00 … (ATA bus error)` Emask 0x50 (host/system bus class) — i.e. **cross-controller corruption**, then freeze.
- Both SSDs show **0 SATA_CRC_Error / 0 reallocated** in SMART (links electrically clean). A **brand-new ADATA reproduced the freeze**.
- Reproducible oddity: **survivor-alone often won't boot** (hangs/panics after pool import); **adding `…800457` back lets it boot.** Not fully explained (see Open questions).

## Investigation & what it ruled out
| Suspect | Verdict | Why |
|---|---|---|
| Dying SanDisk `…800457` | **Not the host-wedge cause** | A brand-new ADATA reproduces the freeze; SMART CRC=0; faults cross to the *other* controller. (The drive *may* still be independently marginal — link negotiates 3.0 Gb/s vs survivor's 6.0 — but it is not what wedges the host.) |
| Bad SATA cable | **No** | SMART SATA_CRC_Error = 0 on both. |
| Memory / RAM | **Largely ruled out** | ~3 days MemTest clean at purchase. |
| PCIe ASPM | **Not active** | `LnkCtl: ASPM Disabled` on both SATA controllers already. |
| **SATA link power management (DIPM/DevSleep)** | **Necessary fix but NOT sufficient** | Initial lead (kernel default `CONFIG_SATA_MOBILE_LPM_POLICY=3` → `med_power_with_dipm`; cheap SSDs mis-handle DIPM). External confirmation below. **BUT** the scrub hung **with the policy verifiably at `max_performance` (LPM off)**, and a boot with `libata.force=nolpm` active **still panicked with power-state errors.** So SATA LPM is at most one layer. |

### External confirmation this *class* of bug is real (it is)
- **AMD/ASUS** acknowledge the AMD FCH SATA controller defaulting to `med_power_with_dipm` under Linux is problematic, and document a BIOS workaround (AMD CBS → FCH → SATA → "AHCI as ID 0x7904"). https://www.asus.com/me-en/support/faq/1049364/
- **Debian kernel bug, same controller** ("AMD 600 Series Chipset SATA Controller rev 01") + cheap DRAM-less SSD → random multi-second freezes + SATA resets, root-caused to `CONFIG_SATA_MOBILE_LPM_POLICY=3`, **fixed with `ahci.mobile_lpm_policy=1`**. https://www.mail-archive.com/debian-kernel@lists.debian.org/msg143011.html
- Kernel 6.9+ broadened auto-LPM; some cheap SSDs **report DIPM support then hang when it's used** — explains why a brand-new ADATA also fails. https://bbs.archlinux.org/viewtopic.php?id=296144
- Same-platform precedent on this very box: the **NVMe drives** previously dropped out and needed `nvme_core.default_ps_max_latency_us=0` (APST off) — i.e. this board has a **documented history of power-state-transition link drops behind its PCIe switches** (see `ansible/prom_prox/nvme_readme.txt`, which literally notes "Reboot will hang").

## What was applied (2026-06-26)
- **Live (lost on reboot):** set all 8 SATA ports `link_power_management_policy=max_performance`.
- **Persisted** in `/etc/kernel/cmdline` (+ fixed a latent **2-line cmdline bug** where an intended `pcie_port_pm=off` sat on line 2 and was never read by proxmox-boot-tool): single line now =
  `root=ZFS=rpool/ROOT/pve-1 boot=zfs vmlinuz video=vesafb:ywrap,mtrr initrd=initrd.magic nvme_core.default_ps_max_latency_us=0 libata.force=nolpm`
  then `proxmox-boot-tool refresh` (verified `libata.force=nolpm` baked into all 3 boot entries on the registered ESP). Backup: `/etc/kernel/cmdline.bak-20260626`.
- **Result: did NOT fix it.** Scrub still hung (LPM verifiably off); survivor-alone boot still power-state-panicked. Keep `libata.force=nolpm` (correct for a server, harmless) but it is **not the cure**. NB the sysfs policy still read `med_power_with_dipm` under `libata.force=nolpm` → if testing the SATA-LPM angle again, prefer **`ahci.mobile_lpm_policy=1`** (verifiably flips the policy).

## Leading hypotheses now
1. **Platform / AGESA / Infinity-Fabric / chipset power-state instability (PRIMARY).** Fits: "power state" on the panic screen, cross-controller corruption (a layer above either SATA controller), instant log-less freeze, old AGESA (1.2.0.3g), and LPM-off not helping. Memtest-clean weakens the pure-RAM angle but not IF/chipset.
2. **This cheap-SSD + AMD-600-chipset-SATA combo is just fragile under sustained I/O** — independent of the OS LPM knob. NVMe on the same box is flawless.

## Recommended path (do in ONE planned maintenance window, fleet down)
1. **Update BIOS 3.50 → 4.41** (major AGESA jump; explicit memory/stability notes). Single most-likely cure. Re-apply settings after (flash resets them). While in BIOS: SATA "Aggressive Link Power Management" → Disabled (if present); defensively Power Supply Idle Control → "Typical Current Idle" and Global C-State Control as desired.
2. **Re-test under load** (a watched `zpool scrub` of the current mirror) **before** trusting it.
3. **Strongly consider moving the boot pool OFF chipset SATA onto NVMe.** NVMe on this box has zero errors ever; a small NVMe boot mirror would make this entire class of fault disappear. This is the most durable fix if BIOS 4.41 doesn't fully settle it.
4. Only **after** prom is provably stable under load: redo the mirror (the ADATA, or keep `…800457` if it proves clean). The rebuild is trivial once the platform stops hanging.
5. Remaining storage knobs to stack if pursuing the SATA angle: `ahci.mobile_lpm_policy=1`, `libata.force=noncq`, `libata.force=3.0G`.

## Evidence-capture for next time
These freezes log **nothing** (pstore empty, journal truncated, and **Loki is on a VM on prom so it dies too**). The only real evidence is the **screen** — if it panics again, **photograph the monitor** (exact "power state" wording / subsystem / stack trace). That photo is worth more than all the logs.

## Open questions
- Why does **survivor-alone** frequently fail to boot while **survivor + `…800457`** boots? (ZFS degraded-import hitting a block needing redundancy? power-draw/enumeration timing changing the power-state path? unknown.) Don't chase it by repeatedly pulling drives — re-test only after the platform is stabilised.
- Is `…800457` independently healthy or genuinely marginal (3.0 Gb/s link cap)? Can only be judged fairly once the host stops hanging.
