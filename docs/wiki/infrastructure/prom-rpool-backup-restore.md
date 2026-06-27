# prom rpool — off-box backup + bare-metal restore runbook

**Date:** 2026-06-26 · **Status:** backup taken **and verified** (zstd + sha256 + zfs-stream); restore procedure documented, **not yet drill-tested end-to-end**.
**Related:** GitHub issue **#276** (the SanDisk boot-mirror SATA saga — read it for the hardware story).

> **Why this doc lives in git, not Forgejo:** Forgejo (`git.ablz.au`) runs on a VM **on prom**. If prom is dead, Forgejo is dead too. This runbook is committed to the repo so it is replicated across every clone (your laptop, epi, the GitHub mirror) and readable offline when prom is down. **Pull it locally and keep a copy.**

---

## TL;DR — where the backup is

A full `zfs send -R` image of prom's **rpool** (the Proxmox host root pool) lives on **tower**:

| | |
|---|---|
| **Host** | tower (Unraid), `192.168.1.2`, `ssh root@tower` (fleet key, from doc1) |
| **Path** | `/mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-2026-06-26.zfs.zst` |
| **Sidecar** | `…/prom-rpool-FULL-2026-06-26.zfs.zst.sha256` |
| **Compressed size** | `17,863,415,460` bytes (16.6 GiB) |
| **Decompressed stream** | `34,331,377,288` bytes |
| **sha256** | `e58e800f7597330756d8f2b4f3f0bec2543d8e6401eb60b5ea6db6478cf64096` |
| **Source snapshot** | `rpool@pre-rebuild-2026-06-26` (recursive, still on prom) |

Pull it from anywhere with the fleet key: `ssh root@tower 'cat /mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-2026-06-26.zfs.zst' > rpool.zfs.zst`

---

## What is — and is NOT — in this backup

**IN:** the entire Proxmox **host** root pool:
- `rpool/ROOT/pve-1` — the PVE host OS (`/`), including `/var/lib/pve-cluster/config.db` (the pmxcfs database = **all VM/CT definitions, `storage.cfg`, cluster identity, firewall, users**).
- `rpool/var-lib-vz` — `/var/lib/vz` (ISOs, CT templates, host-level dump backups).
- `rpool/data` — empty placeholder.

**NOT IN — important:** the actual **VM/CT disk images**. Those live on physically separate NVMe drives and are untouched by an rpool loss:
- `nvmeprom` ZFS pool — 3× Samsung 990 PRO 2TB → most zvols (doc1, doc2, igpu, gaming VMs, …).
- `Test` LVM-thin — 1× Crucial T700 2TB → a few VM disks.

So if only the **boot SSDs** die (the common case — see #276), the VM *data* on NVMe is fine and you only restore rpool below. The NVMe pools have their **own, separate** backup story (PBS / syncoid / kopia per service) — **not covered here**.

---

> **Update 2026-06-27 — RESOLVED:** the boot-SSD saga was a **single faulty drive** (SanDisk `…802287`) dropping its SATA link under load — *not* cables, the controller, or a power-state/platform issue. It was removed and the mirror rebuilt as **`…800457` + ADATA SU650** (1.5 Gb/s, NCQ off). Full post-mortem: [prom-sata-power-state-hangs.md](prom-sata-power-state-hangs.md); current host config: [prom-hypervisor.md](prom-hypervisor.md). This backup is the off-box safety net that made the rebuild safe to attempt.

## Hardware context (the short version of #276)

prom's rpool was a 2-way ZFS mirror of two cheap consumer SATA SSDs (SanDisk SSD PLUS 240GB). The diagnosis flipped during the rebuild: the genuinely **faulty** drive turned out to be **`24370L802287`** (it drops its SATA link under sustained load — full story in [prom-sata-power-state-hangs.md](prom-sata-power-state-hangs.md)), *not* `…800457` as #276 first assumed. **Resolution (2026-06-27):** removed `…802287`; rpool is now a mirror of **`24370L800457` + ADATA SU650 256GB (`4P3621994623`)** at 1.5 Gb/s with NCQ off. This backup was taken mid-rebuild as the off-box safety net.

**Key fact (still true):** a ZFS mirror imports off a single leg, and each rpool drive now carries a managed ESP (systemd-boot + all kernels), so **any one SSD = a bootable prom.** The backed-up *data* (host OS + `/etc/pve`) is unchanged by the drive swap, so this image remains a valid restore source.

---

## Restore scenario A — prom won't boot but a boot SSD is intact (MOST LIKELY)

You almost certainly **don't need the tower image**. The surviving SSD is a full bootable copy; the usual failure is the motherboard UEFI picking the wrong/absent boot entry, not data loss.

1. At the prom console, hit the **boot-override menu** (F11 / F8 on this board) → pick **"Linux Boot Manager"** (systemd-boot) or **"UEFI OS"**. It will boot off whichever SSD is healthy.
2. If no usable entry exists, boot a **Proxmox VE ISO → Advanced → Install in debug mode** (drops to a shell with ZFS), or any Linux live USB with zfs, then:
   ```sh
   zpool import -f rpool
   # rewrite boot entries onto the healthy ESP (find it: lsblk -o NAME,PARTTYPE,PARTUUID; the EF00/1G one)
   proxmox-boot-tool init /dev/disk/by-id/<healthy-disk>-part2
   zpool export rpool
   reboot
   ```

---

## Restore scenario B — full bare-metal rpool restore from the tower image

Use this only if **both** boot SSDs are gone/unreadable. Needs: a live env with `zfs` + `zstd` + network to tower, and a target SSD (≥ the original 222 GiB ZFS partition).

1. **Boot** a Proxmox VE installer ISO → *Advanced → Install in debug mode* (second shell), or a NixOS/Ubuntu live USB with zfs.

2. **Fetch + verify** the image:
   ```sh
   ssh root@tower 'cat /mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-2026-06-26.zfs.zst' > /tmp/rpool.zfs.zst
   sha256sum /tmp/rpool.zfs.zst   # MUST equal e58e800f7597330756d8f2b4f3f0bec2543d8e6401eb60b5ea6db6478cf64096
   ```

3. **Partition** the new SSD to match prom's Proxmox-ZFS-root layout (EF02 BIOS-boot · EF00 1G ESP · BF01 ZFS):
   ```sh
   DISK=/dev/disk/by-id/ata-<your-new-ssd>     # NOT /dev/sdX — use by-id
   sgdisk -Z "$DISK"
   sgdisk -a1 -n1:34:2047    -t1:EF02 "$DISK"  # ~1 MiB BIOS boot (legacy GRUB embed)
   sgdisk      -n2:2048:+1G   -t2:EF00 "$DISK"  # 1 GiB ESP
   sgdisk      -n3:0:0        -t3:BF01 "$DISK"  # remainder = ZFS
   ```

4. **Create the pool** (match prom's props: `ashift=12`, `compression=on`, `xattr=sa`) **and receive** the stream under an altroot so it doesn't mount over your live env:
   ```sh
   zpool create -f -o ashift=12 -O compression=on -O xattr=sa -O relatime=on \
     -m none -R /mnt/restore rpool "${DISK}-part3"
   zstd -dc /tmp/rpool.zfs.zst | zfs receive -F rpool
   ```
   The `-R` send carries per-dataset properties and mountpoints (`rpool/ROOT/pve-1 → /`, etc.); the `-R /mnt/restore` altroot keeps them from mounting live.

5. **Reinstall the bootloader** so the disk boots standalone:
   ```sh
   zpool set bootfs=rpool/ROOT/pve-1 rpool
   proxmox-boot-tool format "${DISK}-part2"
   proxmox-boot-tool init   "${DISK}-part2"
   ```

6. `zpool export rpool`, remove the live USB, reboot. prom comes up on the restored SSD.

7. **(Recommended) re-mirror:** partition a second SSD identically (steps 3), then
   ```sh
   zpool attach rpool "${DISK}-part3" /dev/disk/by-id/ata-<second-ssd>-part3
   proxmox-boot-tool init /dev/disk/by-id/ata-<second-ssd>-part2   # so BOTH can boot
   ```

---

## Restore scenario C — host is fine, I just need the VM/CT configs back

`/etc/pve` is a FUSE mount of pmxcfs; the persistent data is `…/var/lib/pve-cluster/config.db` inside `rpool/ROOT/pve-1`. Receive the image into a scratch dataset and lift the file out:
```sh
zstd -dc /tmp/rpool.zfs.zst | zfs receive -F tank/rpool-restore
# old root fs is at: /<altroot>/.../ROOT/pve-1  →  var/lib/pve-cluster/config.db
# stop pve-cluster, drop the old config.db in /var/lib/pve-cluster/, start it → /etc/pve repopulates
```

---

## How this backup was made (to re-take it)

Run **from doc1** — it is the bastion that can reach both prom and tower. **prom cannot `ssh tower` directly** (it is not in the fleet bastion model — "Host key verification failed"), so the stream is pulled through doc1:

```sh
TAG=pre-rebuild-$(date +%F)
ssh root@192.168.1.12 "zfs snapshot -r rpool@$TAG"
ssh root@192.168.1.12 "zfs send -R rpool@$TAG | zstd -T0 -3" \
  | ssh root@tower "cat > /mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-$TAG.zfs.zst"
# verify
ssh root@tower "cd /mnt/user/VMBackups/prom-rpool && zstd -t prom-rpool-FULL-$TAG.zfs.zst \
  && sha256sum prom-rpool-FULL-$TAG.zfs.zst | tee prom-rpool-FULL-$TAG.zfs.zst.sha256"
```

## prom rpool reference (as of 2026-06-26)

- Pool: `ashift=12`, `autotrim=off`, mirror-0 of two SanDisk SSD PLUS 240GB SATA SSDs.
- Datasets: `rpool` (compression=on, xattr=sa), `rpool/ROOT/pve-1` (`/`, acltype=posix), `rpool/var-lib-vz` (`/var/lib/vz`), `rpool/data` (empty). ~21.7 G allocated of 220 G.
- Survivor SSD partition layout (clone template): p1 `34–2047` EF02 · p2 `2048–2099199` EF00 (1 GiB ESP) · p3 `2099200–467664896` BF01 (222 GiB ZFS).

## Verification status (2026-06-26)

- ✅ zstd container integrity — `zstd -t` → OK.
- ✅ sha256 recorded above; `.sha256` sidecar written next to the file on tower.
- ✅ ZFS stream structural validation — `zstd -dc … | zstreamdump` → exit 0, all 6 datasets parsed, 482,066 write records, valid END checksums, and **total stream length `34,331,377,288` exactly matches** the decompressed size. The image is structurally complete and internally consistent.
- ⬜ **Not** yet drill-tested with a real end-to-end `zfs receive` onto a spare disk. Do this if you want belt-and-suspenders before relying on scenario B.
