# prom — Proxmox hypervisor (host config reference)

**Host:** `prom` · 192.168.1.12 · AMD Ryzen 9 9950X · ASRock X870E Taichi Lite · Proxmox VE 9.2 (kernel 7.0.12-1-pve)
**Status:** ✅ stable as of **2026-06-27**. This is the canonical record of prom's kernel flags, boot pool, and bootloader setup.

> prom is **not** a NixOS host — it's a hand-managed Proxmox install. Its host-level config (kernel cmdline, ESPs, ZFS pools) is managed **directly on the box**, *not* via this flake and **no longer via Ansible** (see [Management](#management)).

## Hardware
- **CPU/board:** Ryzen 9 9950X (Zen 5, AM5), ASRock **X870E Taichi Lite**, BIOS AMI 3.50 (AGESA ComboAM5 1.2.0.3g). 128 GB DDR5-5600 (2×64 GB Micron) — MemTest clean ~3 days at purchase.
- **SATA:** only the AMD 600-series **chipset** SATA (two controllers, `[1022:43f6]`, behind the chipset PCIe switches). **No discrete/third-party SATA on this board** — the only ways off chipset SATA are NVMe or a PCIe HBA.
- **PCIe slots:** PCIE1 = GTX 1080 (passthrough); **PCIE2 (CPU-fed x8) is the one free slot.** All 4 M.2 slots populated.
- **Storage:**
  - **`rpool`** (boot/root, ZFS mirror, chipset SATA): SanDisk SSD PLUS 240GB **`24370L800457`** + **ADATA SU650 256GB `4P3621994623`**. ~22 GB used. *(The original mirror's other half, SanDisk `…802287`, was faulty and removed — see below.)*
  - **`nvmeprom`** (VM storage, ZFS): 3× Samsung 990 PRO 2TB. Flawless.
  - 1× Crucial T700 2TB NVMe → LVM-thin `Test` (gaming/test VMs).
- **GPUs (passthrough):** NVIDIA GTX 1080 (PCIE1) + CPU iGPU.

## Boot pool (rpool) — the SATA reliability config
The rpool mirror had a long host-freeze saga that turned out to be **one faulty SanDisk drive (`…802287`) dropping its SATA link under load** — full post-mortem in [prom-sata-power-state-hangs.md](prom-sata-power-state-hangs.md), resolved 2026-06-27 by replacing it with the ADATA. We settled on a deliberately conservative, **reliability-over-speed** config (the boot pool does almost nothing, so the cost is nil).

### Kernel cmdline + why each flag
File: **`/etc/kernel/cmdline`** (single line; pushed to the ESPs with `proxmox-boot-tool refresh`). Current:
```
root=ZFS=rpool/ROOT/pve-1 boot=zfs vmlinuz video=vesafb:ywrap,mtrr initrd=initrd.magic nvme_core.default_ps_max_latency_us=0 ahci.mobile_lpm_policy=1 libata.force=1.5G,noncq pcie_aspm=off pcie_port_pm=off
```

| Flag | What it does / why | Load-bearing? |
|---|---|---|
| `nvme_core.default_ps_max_latency_us=0` | Disables NVMe **APST** — pre-existing fix for the 990 PROs dropping out (power-state transitions behind the chipset PCIe switches). | Yes (for NVMe). |
| `ahci.mobile_lpm_policy=1` | SATA link power management → `max_performance` (off). The distro default `med_power_with_dipm` is laptop-oriented and a **known host-hang trigger** on AMD chipset SATA; `max_performance` is the correct setting for a 24/7 server. | **Keep regardless.** |
| `libata.force=1.5G,noncq` | Caps SATA links to **1.5 Gb/s** (max signal-integrity margin; ~150 MB/s is 7× what a boot pool needs) and disables **NCQ** (so a link reset can't deadlock the AHCI controller). ⚠️ The `,noncq` half is **silently dropped** by libata's combine parser — noncq is actually enforced by the udev rule below. | Defence-in-depth (harmless here). |
| `pcie_aspm=off` / `pcie_port_pm=off` | PCIe ASPM + port power-management off (precautionary; ASPM was *already* off on the SATA controllers via BIOS). Costs a little idle power. | Least load-bearing — safe to drop if leaning out. |

### noncq is delivered by a udev rule (not the cmdline)
Because `libata.force=…,noncq` doesn't stick, NCQ-off is enforced by **`/etc/udev/rules.d/99-sata-noncq.rules`** (applies early at boot, on the root fs so it survives any ESP change):
```
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{device/queue_depth}="1"
```
Verify live: `cat /sys/block/sd?/device/queue_depth` → `1`.

## Bootloader / ESP setup
Proxmox systemd-boot + ZFS-on-root. **Both** rpool drives carry a managed ESP, so either can boot the host on its own:
- `0274-8B86` → `…800457`
- `F831-24C0` → ADATA

Check: `proxmox-boot-tool status` (both should list all kernels). After any `/etc/kernel/cmdline` change: `proxmox-boot-tool refresh`.

⚠️ **Gotcha — udev race after `format`:** `proxmox-boot-tool format <part2>` creates a fresh vfat, but the `/dev/disk/by-uuid/<UUID>` symlink lags, so `init` skips with *"does not exist"*. Run **`udevadm settle`** (or `udevadm trigger --settle --action=add <part2>`) **after** format, **before** init. (Don't `udevadm trigger` a *whole disk* while a SATA link is flapping — it forces a partition re-scan that reads the bad drive and can wedge rpool I/O.)

## SSH / management gotchas
- prom is **not** in the fleet SSH bastion model. Reach it from doc1: `ssh root@192.168.1.12` (fleet key). prom **cannot** `ssh tower` directly — route tower transfers **through doc1**.
- Long-running doc1 agent sessions can hit a **stale forwarded ssh-agent** (`ssh-add -l` hangs → *every* agent-auth ssh hangs, looking like the host is wedged). Bypass with the key directly:
  ```
  SSH_AUTH_SOCK= ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@192.168.1.12
  ```

## Off-box backup
A full rpool image lives on **tower**; restore runbook: [prom-rpool-backup-restore.md](prom-rpool-backup-restore.md). Automating this as a recurring service is tracked in Forgejo (catastrophic-recovery safety net).

## Management
prom's host config is hand-managed **on the box** — `/etc/kernel/cmdline`, `proxmox-boot-tool`, `zpool`, the udev rule above. **The old `ansible/prom_prox/nvme.yml` + `nvme_readme.txt` NVMe-power playbook is DEPRECATED / no longer used** — its one job (the NVMe APST cmdline param) is now part of the directly-managed cmdline documented here. This page is the source of truth.
