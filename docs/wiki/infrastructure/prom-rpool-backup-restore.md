# prom rpool — off-box backup + bare-metal restore runbook

**Date:** 2026-06-26 (initial); encrypted + automated 2026-07-01  
**Status:** automated weekly service running (doc1 `prom-rpool-backup.service`); restore procedure documented, **not yet drill-tested end-to-end**.  
**Related:** GitHub issue **#276** (the SanDisk boot-mirror SATA saga — read it for the hardware story); issue **#17** (backup automation tracking).

> **Why this doc lives in git, not Forgejo:** Forgejo (`git.ablz.au`) runs on a VM **on prom**. If prom is dead, Forgejo is dead too. This runbook is committed to the repo so it is replicated across every clone (your laptop, epi, the GitHub mirror) and readable offline when prom is down. **Pull it locally and keep a copy.**

---

## TL;DR — where the backup is

A full `zfs send -R` image of prom's **rpool** (the Proxmox host root pool) is automatically taken weekly and **age-encrypted** before landing on tower:

| | |
|---|---|
| **Service** | `prom-rpool-backup.service` on doc1 (weekly Mondays 03:30 AWST) |
| **Host** | tower (Unraid), `192.168.1.2`, `ssh root@tower` (fleet key, from doc1) |
| **Path** | `/mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age` |
| **Sidecar** | `…/prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age.sha256` |
| **Encryption** | age (ChaCha20-Poly1305 AEAD); break-glass key (Bitwarden) OR doc1 editor key |
| **Count kept** | 4 most-recent on tower; oldest auto-pruned |

---

## Encryption

Archives are encrypted **in flight on doc1** using `age -e` before writing to tower. Two decryption keys exist:

| Key | Location | Use case |
|---|---|---|
| **doc1 editor key** | `~/.config/sops/age/keys.txt` on doc1 | Normal ops, on-demand restore |
| **break-glass key** | Bitwarden vault + printed copy | Disaster recovery when doc1 is gone |

Either key alone decrypts. The plaintext private keys are never stored on tower or prom.

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

Use this only if **both** boot SSDs are gone/unreadable. Needs: a live env with `zfs` + `zstd` + `age` + network to tower, and a target SSD (≥ the original 222 GiB ZFS partition).

1. **Boot** a Proxmox VE installer ISO → *Advanced → Install in debug mode* (second shell), or a NixOS/Ubuntu live USB with zfs. Install `age` if not present: `apt install age` or `nix run nixpkgs#age`.

2. **Fetch the encrypted image** from tower:
   ```sh
   ssh root@tower 'cat /mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age' > /tmp/rpool.zfs.zst.age
   ```
   (Use the most recent date, or pull the sha256 sidecar to confirm which file to use.)

3. **Verify + decrypt + receive** in one pipeline:
   ```sh
   # Option A — using the doc1 editor key (retrieve from doc1 if it's reachable):
   age -d -i /path/to/editor-key.txt /tmp/rpool.zfs.zst.age | zstd -dc | zfs receive -F rpool

   # Option B — using the break-glass key from Bitwarden:
   age -d -i /path/to/breakglass-key.txt /tmp/rpool.zfs.zst.age | zstd -dc | zfs receive -F rpool
   ```

   Or, to inspect the sha256 before decrypting (verifies the encrypted blob's integrity):
   ```sh
   sha256sum /tmp/rpool.zfs.zst.age   # compare against the .sha256 sidecar on tower
   ```

4. **Create the pool** first (match prom's props: `ashift=12`, `compression=on`, `xattr=sa`) and receive under an altroot:
   ```sh
   DISK=/dev/disk/by-id/ata-<your-new-ssd>     # NOT /dev/sdX — use by-id
   sgdisk -Z "$DISK"
   sgdisk -a1 -n1:34:2047    -t1:EF02 "$DISK"  # ~1 MiB BIOS boot (legacy GRUB embed)
   sgdisk      -n2:2048:+1G   -t2:EF00 "$DISK"  # 1 GiB ESP
   sgdisk      -n3:0:0        -t3:BF01 "$DISK"  # remainder = ZFS

   zpool create -f -o ashift=12 -O compression=on -O xattr=sa -O relatime=on \
     -m none -R /mnt/restore rpool "${DISK}-part3"
   age -d -i /path/to/key.txt /tmp/rpool.zfs.zst.age | zstd -dc | zfs receive -F rpool
   ```
   The `-R` send carries per-dataset properties and mountpoints (`rpool/ROOT/pve-1 → /`, etc.); the `-R /mnt/restore` altroot keeps them from mounting live.

5. **Reinstall the bootloader** so the disk boots standalone:
   ```sh
   zpool set bootfs=rpool/ROOT/pve-1 rpool
   proxmox-boot-tool format "${DISK}-part2"
   proxmox-boot-tool init   "${DISK}-part2"
   ```

6. `zpool export rpool`, remove the live USB, reboot. prom comes up on the restored SSD.

7. **(Recommended) re-mirror:** partition a second SSD identically (step 4), then
   ```sh
   zpool attach rpool "${DISK}-part3" /dev/disk/by-id/ata-<second-ssd>-part3
   proxmox-boot-tool init /dev/disk/by-id/ata-<second-ssd>-part2   # so BOTH can boot
   ```

---

## Restore scenario C — host is fine, I just need the VM/CT configs back

`/etc/pve` is a FUSE mount of pmxcfs; the persistent data is `…/var/lib/pve-cluster/config.db` inside `rpool/ROOT/pve-1`. Decrypt into a scratch dataset and lift the file out:
```sh
# From doc1 (which has the editor key):
ssh root@tower 'cat /mnt/user/VMBackups/prom-rpool/prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age' \
  | age -d -i ~/.config/sops/age/keys.txt \
  | zstd -dc | zfs receive -F tank/rpool-restore
# old root fs is at: /<altroot>/.../ROOT/pve-1  →  var/lib/pve-cluster/config.db
# stop pve-cluster, drop the old config.db in /var/lib/pve-cluster/, start it → /etc/pve repopulates
```

---

## Checking the current backup status

From doc1:
```sh
# Latest backup on tower:
ssh root@tower "ls -lht /mnt/user/VMBackups/prom-rpool/ | head -5"

# Last run status (exit code, duration, error):
sudo cat /var/lib/prom-rpool-backup/.status.json | jq .

# Service logs for the last run:
journalctl -u prom-rpool-backup.service -n 50

# Timer — when it last ran and next run:
systemctl status prom-rpool-backup.timer
```

---

## How this backup was made — automated service

The `prom-rpool-backup.service` on doc1 runs weekly on Mondays at 03:30 AWST. It:

1. Creates `rpool@prom-rpool-YYYY-MM-DD` on prom (recursive, atomic)
2. Pipes `zfs send -R | zstd -T0 -3 | age -e -r <breakglass> -r <editor>` to tower as `.zfs.zst.age.tmp`
3. Renames to final name; writes sha256 sidecar
4. Writes `/var/lib/prom-rpool-backup/.status.json`
5. Prunes tower to keep the 4 most recent `.zfs.zst.age` files
6. Prunes prom snapshots to keep the 2 most recent tags

Source: `modules/nixos/services/prom-rpool-backup.nix`. Enable in `hosts/proxmox-vm/configuration.nix`.

To re-run manually (from doc1): `sudo systemctl start prom-rpool-backup.service`

---

## Verification

The sha256 sidecar covers the encrypted blob (detects bitrot on tower). Age's AEAD (ChaCha20-Poly1305) verifies integrity at decrypt time — any corruption in the ciphertext causes `age -d` to fail. To manually verify and check decryptability from doc1:

```sh
# Check sha256 of the encrypted file on tower:
ssh root@tower "cd /mnt/user/VMBackups/prom-rpool && sha256sum -c prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age.sha256"

# Test decrypt (verifies age header + AEAD, does NOT receive into ZFS):
ssh root@tower "cat prom-rpool-FULL-YYYY-MM-DD.zfs.zst.age" \
  | age -d -i ~/.config/sops/age/keys.txt \
  | zstd -dc | zstreamdump | tail -3
```

`zstreamdump` exit 0 with a valid END record = stream is structurally complete and the decryption chain works.

---

## Hardware context (as of 2026-06-27)

prom's rpool is a 2-way ZFS mirror: `24370L800457` (SanDisk SSD PLUS 240GB) + `4P3621994623` (ADATA SU650 256GB) at 1.5 Gb/s with NCQ off. The faulty drive `24370L802287` (dropped SATA link under load) was removed. Either surviving disk is bootable standalone. Full post-mortem: [prom-sata-power-state-hangs.md](prom-sata-power-state-hangs.md).

- Pool: `ashift=12`, `autotrim=off`, ~21.7 G allocated of 220 G.
- Datasets: `rpool` (compression=on, xattr=sa), `rpool/ROOT/pve-1` (`/`, acltype=posix), `rpool/var-lib-vz` (`/var/lib/vz`), `rpool/data` (empty).
- Partition layout per disk: p1 `34–2047` EF02 · p2 `2048–2099199` EF00 (1 GiB ESP) · p3 `2099200–467664896` BF01 (222 GiB ZFS).
