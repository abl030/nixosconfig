# prom — Proxmox hypervisor (host config reference)

**Host:** `prom` · 192.168.1.12 · AMD Ryzen 9 9950X · ASRock X870E Taichi Lite · Proxmox VE 9.2 (kernel 7.0.12-1-pve)
**Status:** ✅ stable as of **2026-09-22**. This is the canonical record of prom's kernel flags, boot pool, bootloader setup, cluster/quorum posture, and LAN-boundary ARP capture.

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

## Cluster / quorum (single-node, no QDevice)
**prom is a standalone single-node Proxmox "cluster" (`grevcluster`, config_version 28): `Expected votes: 1`, `Quorum: 1`, `Flags: Quorate`, no QDevice, no other voting nodes.** Nothing external is needed for quorum — `qm` / `pct` / firewall writes to pmxcfs (`/etc/pve`) always work. **If prom is ever non-quorate now, that's a NEW fault — do not go hunting for a witness to revive.**

**History.** Until **2026-07-02** prom was a single node **plus an external corosync QDevice witness** (`corosync-qnetd`) that ran **inside the old `Caddy2.0` KVM VM (`192.168.1.6`) on tower** → expected votes = 2, quorum = 2. So whenever `Caddy2.0` was down, prom dropped to 1/2 → `Quorate: No, Activity blocked` → **pmxcfs read-only** → every write failed (`qm clone`/`qm set` → `cluster not ready - no quorum?`; firewall edits → `Permission denied`; reads still served from cache). This bit the gaming golden-image builds — see [apollo-gaming-vm.md](../services/apollo-gaming-vm.md).

**Why it was removed.** The edge services migrated off the old caddy VM onto **LXC 108 (`caddy-new`)**, which reuses the **same IP+MAC `192.168.1.6`**. Stopping the old VM at cutover killed the witness and wedged prom. Reviving the VM to "fix" quorum was impossible — it would collide on IP+MAC with the live LXC 108. So the witness dependency was retired entirely: prom is now self-quorate on its own single vote.

**Recovery recipe — regain quorum when a QDevice host is gone (reusable).** `pvecm expected 1` does **not** work while a qdevice is configured (corosync ignores the manual override — it returns exit 0 but changes nothing), and `pvecm qdevice remove` needs quorum to write corosync.conf → deadlock. Break it by editing corosync.conf in **local mode** (`pmxcfs -l` makes `/etc/pve` writable *without* quorum):
```
systemctl stop pve-cluster corosync
systemctl stop corosync-qdevice; systemctl disable corosync-qdevice
pmxcfs -l
# edit /etc/pve/corosync.conf: delete the quorum{device{...}} stanza (keep
#   provider: corosync_votequorum), delete any dead node from nodelist, bump config_version
cp /etc/pve/corosync.conf /etc/corosync/corosync.conf   # keep both files identical
killall pmxcfs
systemctl start corosync; systemctl start pve-cluster
pvecm status   # -> Quorate: Yes, Expected 1, Flags: Quorate, no Qdevice
```
The end state must have **exactly one node and no device** so `expected=1` is unambiguous and reboot-safe (this sidesteps corosync's "never-seen node" and no-downscale high-water quirks — with a lone node there's no ambiguity). prom has **no HA resources**, so the CRM watchdog stays on **standby** and a quorum change won't self-fence the node (confirmed: prom sat non-quorate for a while without rebooting). Done 2026-07-02; the phantom `epi` (nodeid 1, `192.168.1.5`) nodelist entry was dropped in the same edit; pre-change backups on prom at `/root/corosync.conf.*.pre-qdevice-removal`.

## Off-box backup
A full rpool image lives on **tower**; restore runbook: [prom-rpool-backup-restore.md](prom-rpool-backup-restore.md). Automating this as a recurring service is tracked in Forgejo (catastrophic-recovery safety net).

## LAN-boundary ARP capture

Prom continuously records ARP crossing the physical boundary between its Linux
bridge and the USW Flex Mini. This exists to diagnose transient address-conflict
and forwarding faults without guessing an affected IP in advance.

- `prom-arp-capture@in.service` records frames arriving from the Flex Mini on
  `enp8s0`.
- `prom-arp-capture@out.service` records frames leaving Prom through `enp8s0`.
- The filter includes untagged, single-tagged, and double-tagged ARP. It does not
  filter on an IP or MAC address.
- Each packet is capped at 128 bytes, enough for the complete Ethernet/VLAN/ARP
  frame. No IP payload is collected.
- Each running instance writes a 125 MB `tcpdump` ring. On restart, the wrapper
  preserves up to 125 MB from earlier runs before starting a uniquely named new
  ring. The hard steady-state bound is therefore 250 MB per direction, 500 MB
  total.
- `-p` avoids promiscuous mode. Separate `-Q in` and `-Q out` captures retain the
  direction that a single Ethernet pcap cannot encode.
- The service runs as Debian's `tcpdump` user with only `CAP_NET_RAW`; systemd
  denies IP sockets and makes the rest of the host filesystem read-only.

The tracked service and wrapper live in `scripts/prom-arp-capture/`. They are
installed directly on Prom because the hypervisor is not a NixOS fleet host:

```bash
scp scripts/prom-arp-capture/prom-arp-capture \
  root@prom:/usr/local/libexec/prom-arp-capture
scp scripts/prom-arp-capture/prom-arp-capture@.service \
  root@prom:/etc/systemd/system/prom-arp-capture@.service
ssh root@prom 'chmod 0755 /usr/local/libexec/prom-arp-capture && \
  chmod 0644 /etc/systemd/system/prom-arp-capture@.service && \
  systemctl daemon-reload && \
  systemctl enable --now prom-arp-capture@in.service prom-arp-capture@out.service'
```

Check the live writers and their security boundary:

```bash
ssh root@prom 'systemctl is-active prom-arp-capture@in.service prom-arp-capture@out.service; \
  systemctl is-enabled prom-arp-capture@in.service prom-arp-capture@out.service; \
  systemd-analyze security prom-arp-capture@in.service --no-pager; \
  find /var/lib/prom-arp-capture -type f -name "*.pcap*" -ls'
```

After an incident, copy both direction directories before restarting either
service. Read captures with `tcpdump -nn -e -tttt -r <file>` or Wireshark. A
suspicious reply in `in/` arrived from the Flex side; one in `out/` originated on
Prom or one of its guests.

## Management
prom's host config is installed directly **on the box**. Repeatable host-level
artifacts may be tracked under `scripts/` and are linked from this page. Kernel,
storage, and boot configuration remains hand-managed through
`/etc/kernel/cmdline`, `proxmox-boot-tool`, `zpool`, and the udev rule above.
**The old `ansible/prom_prox/nvme.yml` + `nvme_readme.txt` NVMe-power playbook is
DEPRECATED / no longer used**. Its one job, the NVMe APST cmdline parameter, is
now part of the directly managed cmdline documented here. This page is the
source of truth.
