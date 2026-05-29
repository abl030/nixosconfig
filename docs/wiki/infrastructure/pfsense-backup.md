# pfSense backup architecture

**Date built:** 2026-05-23
**Major rearchitect:** 2026-05-26 (moved off prom virtiofs/NFS to native ZFS on doc2)
**Status:** Live. Daily syncoid pull from pfSense → doc2 at 03:00 AWST.
**Related:** [pfsense-dns-resolver](pfsense-dns-resolver.md), [dns-saturation-incident-2026-05-22](dns-saturation-incident-2026-05-22.md).

## TL;DR

Three-layer defence in depth for the bare-metal pfSense firewall (Protectli FW4C, ZFS-on-root, 30 GB SSD):

1. **AutoConfigBackup (ACB)** — Netgate's hosted config-only service. Encrypted client-side, off-site, triggers on every config save. ~32 days history. Password lives in Bitwarden.
2. **ZFS replication to doc2** — syncoid runs *on doc2*, pulls the full pool (minus ntopng's telemetry) into a local ZFS pool `pfsensebackup`. ~1.5 GB initial, KB-MB-scale incrementals. Sanoid retention 30 daily / 8 weekly / 6 monthly.
3. **Kopia off-site replication** — doc2's kopia-mum instance walks `/mnt/backup/pfsense` and ships to mum's Synology over Tailscale.

A watchdog on doc2 reads the JSON status file syncoid writes on every run, AND verifies the canary file (`/mnt/backup/pfsense/ROOT/default/cf/conf/config.xml` ≥ 50 KB) — catches both "syncoid failed" AND "syncoid claims success but child datasets are unreachable." Routes failures through `homelab.monitoring.errorPatterns` → alert-bridge → Gotify.

## Architecture

```
   ┌──────────────────────────────────────────────────────────────┐
   │  pfSense (Protectli FW4C, bare metal, ZFS-on-root pool       │
   │   named "pfSense")                                            │
   │                                                                │
   │   SSH access for syncoid is restricted via authorized_keys    │
   │   forced-command wrapper at /root/.ssh/syncoid-wrapper.sh     │
   │   (only zfs ops + echo probe). Single authorized key from     │
   │   doc2 (prom's key was retired 2026-05-26).                   │
   └────────────────────────┬─────────────────────────────────────┘
                            │  syncoid (pull, daily 03:00 AWST)
                            │  ed25519 key + forced-command
                            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  doc2 (NixOS VM 114 on prom)                                  │
   │                                                                │
   │   Hardware: virtio1 = nvmeprom:vm-114-pfsense-backup (10 GB   │
   │     zvol passthrough from prom).                              │
   │   ZFS pool: pfsensebackup, mountpoint /mnt/backup/pfsense.    │
   │   13 child datasets auto-mount as kernel ZFS submounts:       │
   │     ├─ ROOT/default         (OS + config, ~1.34 GB)           │
   │     │   └─ cf/conf/config.xml (the canary — 175 KB)           │
   │     ├─ var/db               (kea, tailscale, pfblockerng)     │
   │     └─ ... (12 more — see `zfs list -r pfsensebackup`)        │
   │   /mnt/backup/pfsense/.syncoid-status.json (written each run) │
   │                                                                │
   │   Native NixOS modules (declarative, this repo):              │
   │     - modules/nixos/services/syncoid-pfsense.nix              │
   │     - modules/nixos/services/pfsense-backup-watchdog.nix      │
   │   services.sanoid prunes received snapshots (30d/8w/6m).      │
   │                                                                │
   │   homelab.services.kopia.instances.mum.sources includes       │
   │     /mnt/backup/pfsense — daily snapshot to mum's Synology.   │
   └────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
                    Synology (off-site, Tailscale)
```

## Why this shape (and not the older virtiofs/NFS attempts)

The chain *used to* run on prom (Debian/Proxmox host), with syncoid pulling into `nvmeprom/backup/pfsense` and exposing it to doc2 via virtiofs, then via NFS. Both failed on the same root cause: **kernel-level file-system traversal of ZFS child datasets is broken on Proxmox's Linux kernel.**

### virtiofs attempt (original design)

- virtiofsd was launched with `--announce-submounts`, which the kernel docs say will auto-traverse mounts within the shared directory.
- In practice only **one** child mount (`reservation/`) propagated to doc2. The other 12 child datasets were invisible. Kopia ended up backing up only the wrapping dataset (`.syncoid-status.json` — 298 bytes) every day.
- **The watchdog passed.** The status JSON file lived in the wrapping dataset and *did* propagate. The watchdog confirmed "syncoid ran, status file is fresh and ok=true" — but there was no actual data to back up. Silent failure for ~2 days.

### NFS attempt (cutover 1)

- Replaced virtiofs with NFS, hoping `crossmnt` would traverse the children.
- Required removing `fsid=0` from the Music export (the existing NFSv4 pseudo-root) to make room for a second NFSv4 export. nfs-utils auto-generates a pseudo-root at `/` once `fsid=0` is gone. Music clients (epi/fra/wsl) updated to use full path; tower already used `vers=3` so was unaffected.
- The Linux kernel NFS server's `crossmnt` does **not** propagate `fsid=` to child filesystems. ZFS-on-Linux's auto-generated UUIDs end with two zero halves and don't survive the kernel's filehandle round-trip.
- Even with explicit `fsid=$(uuidgen -r)` set per-child (15 export lines, all UUIDs unique), the kernel returned `mount(2): Input/output error` on every child traversal. Direct mounts of child paths failed with mount.nfs error 32.
- Per kernel.org/filesystems/nfs/reexport.html, the fix is either to give every child filesystem an explicit fsid AND a separate export line — already done — OR run a userspace NFS server (nfs-ganesha) which auto-discovers submounts. TrueNAS does the latter; nfs-ganesha was the way forward for this approach.

### Why we chose native ZFS instead of nfs-ganesha (cutover 2)

Going to nfs-ganesha would have:
- Replaced the production kernel NFS server on prom (used by tower/plex, epi, fra, wsl).
- Added a new userspace service to maintain on the imperative-managed Proxmox host.
- Kept the imperative prom-side scripts (`/usr/local/sbin/syncoid-pfsense.sh`, systemd units, `/etc/sanoid/sanoid.conf`, firewall rules, NFS export, virtiofs share, qm config, mapping config) that we'd been accumulating on prom.

Putting ZFS *on the client* (doc2) instead:
- Eliminates the entire "expose ZFS to another host via NFS-or-similar" problem class. Kernel ZFS on doc2 handles child datasets natively — they're real mounts, no fsid bridging needed.
- Brings the syncoid setup into **declarative NixOS** (modules/nixos/services/syncoid-pfsense.nix) instead of imperative-on-prom.
- prom drops out of the backup chain entirely. The only prom-side touch is a 10 GB zvol passthrough — which is just storage, not logic.
- Disaster recovery is preserved: doc2 can `zfs send` back to bare-metal pfSense the same way prom could have.

### Costs accepted

- doc2 must have ZFS-on-Linux compiled in. NixOS handles this — needs `boot.supportedFilesystems = ["zfs"];` plus a stable `networking.hostId`.
- It's a zfs-on-zfs layering (inner ZFS on doc2 sits on a zvol backed by prom's nvmeprom pool). Acceptable: prom's outer ZFS handles redundancy on the 3-NVMe pool; doc2's inner ZFS provides the *features* we need (snapshots, child datasets, ARC, native traversal). Tuned with `compression=off`, `primarycache=metadata`, `sync=disabled` on the outer zvol so the inner layer owns those decisions.

### Boot-race gotcha (observed 2026-05-29)

The `pfsensebackup` pool's device (`vdb`) is a zvol **passed through from prom**, and that virtio disk can attach a few seconds *after* doc2 starts booting. ZFS's import service only waits ~15s, so on an unlucky reboot `zfs-import-pfsensebackup.service` fails with `Pool pfsensebackup in state MISSING ... no such pool available`. It's a `oneshot` with no retry, so the pool never imports — `/mnt/backup/pfsense` stays empty and the watchdog correctly pages `status-file-missing`. The backup *data* is fine; only the mount is absent.

- **Manual recovery:** `ssh doc2 sudo zpool import pfsensebackup` (the pool is healthy and importable, just not imported), then `sudo systemctl reset-failed zfs-import-pfsensebackup.service`.
- **Permanent guard:** `hosts/doc2/configuration.nix` adds an `ExecStartPre` on `zfs-import-pfsensebackup.service` that polls `zpool import` for the pool to appear (up to ~120s) before the real import runs, so a late passthrough disk no longer loses the race.

## What's covered (and what's not)

| Layer | Captures | Doesn't capture |
|---|---|---|
| ACB | `config.xml` (every rule, NAT, VPN, CA, DHCP, DNS settings) | Package binaries, RRD data, lease databases, certificates not in config.xml |
| ZFS replication | Everything in `pfSense/ROOT/*`, `pfSense/var/db`, `pfSense/var/log`, etc. — including installed packages, kea leases, Tailscale identity, pfBlockerNG state | `pfSense/var/db/ntopng` (intentionally excluded — disposable telemetry) |
| Kopia | Whatever the ZFS replication carried, off-site to mum's Synology | Same exclusions |

## Recovery procedures

### Scenario 1: fat-finger config rollback

You broke a firewall rule and want to undo. Don't restore from this stack — ACB has 32 days of per-config-save snapshots and the GUI restore is the right tool.

**Procedure:** pfSense GUI → Diagnostics → Backup & Restore → AutoConfigBackup tab → pick a snapshot → restore. <5 minutes.

### Scenario 2: SSD failure, identical Protectli still working

The mSATA died but the box is fine. You have the ZFS replica on doc2.

**Procedure:**

1. Install a replacement mSATA SSD in the Protectli.
2. Boot pfSense installer ISO from USB. Choose "Shell" not "Install."
3. Wipe and recreate the pool with the same name:
   ```sh
   gpart create -s gpt ada0
   gpart add -t efi -s 260M ada0
   gpart add -t freebsd-boot -s 512K ada0
   gpart add -t freebsd-swap -s 1G ada0
   gpart add -t freebsd-zfs ada0
   zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -m none pfSense ada0p4
   ```
4. From a network-accessible shell on the new pfSense, receive the latest snapshot from doc2:
   ```sh
   # On doc2:
   sudo zfs send -R pfsensebackup@<latest-snapname> | ssh root@<new-pfsense> 'zfs receive -F pfSense'
   ```
5. Set bootfs: `zpool set bootfs=pfSense/ROOT/default pfSense`
6. Install the FreeBSD bootloader to ada0:
   ```sh
   gpart bootcode -p /boot/boot1.efifat -i 1 ada0
   ```
7. Reboot. pfSense should come up byte-identical to the donor.

RTO: ~20-30 min.

### Scenario 3: full Protectli failure, no spare

You need a working firewall and the hardware is gone. Spin pfSense as a VM temporarily.

**Procedure:**

1. Create a new VM on any hypervisor (prom is fine) with the Protectli's profile: UEFI, 4 GB RAM, 2 cores, two NICs (one passed through for WAN).
2. **Receive the backup to a new zvol:**
   ```sh
   # On doc2:
   sudo zfs send -R pfsensebackup@<latest> | ssh root@prom 'zfs receive -F nvmeprom/vm-NNN-pfsense-restore'
   ```
   ...then attach as the VM's root disk on prom.
3. Boot. The pfSense console will prompt to reassign interfaces — the NIC names changed (igc0 → vtnet0). Walk through the prompt.
4. Adjust WAN/LAN assignments in the GUI as needed.

RTO: ~20-30 min once you've got the second NIC passed through. Temporary fix until new Protectli hardware arrives.

### Scenario 4: full house loss

Everything on-prem is gone. Recovery from cloud:

1. New hardware (Protectli or any UEFI-capable mini-PC).
2. Fresh pfSense install from ISO.
3. Restore config from **ACB** via the installer's "Recover config from backup" option (you'll need the encryption password from Bitwarden).
4. If pfBlockerNG fails to re-initialise cleanly (it sometimes does — known Redmine bugs), pull `/var/db/pfblockerng/` and `/usr/local/etc/pfblockerng/` from Kopia (mum's Synology) and drop them in.
5. Tailscale re-auth is required regardless (identity isn't preserved across an ACB-only restore).

RTO: ~1-2 hours assuming hardware on hand. Days if shipping.

## Components and where they live

### On pfSense (FreeBSD; persistent across reboots via pfSense config.xml reconciliation)

- `/root/.ssh/syncoid-wrapper.sh` — forced-command wrapper restricting the syncoid key to `zfs ` and `echo ` commands. This file is **not** managed by pfSense config.xml — it's a raw file that survives reboots independently.
- `/root/.ssh/authorized_keys` — managed via the pfSense user API (config.xml `<authorizedkeys>` field). Contains the single doc2 ed25519 public key with `command="/root/.ssh/syncoid-wrapper.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,no-user-rc` options.

### On doc2 (NixOS — declarative, in this repo)

- `hosts/doc2/configuration.nix` — `boot.supportedFilesystems = ["zfs"]`, `networking.hostId`, `boot.zfs.extraPools = ["pfsensebackup"]`, `homelab.services.syncoidPfsense.enable = true`, `homelab.services.pfsenseBackupWatchdog.enable = true`, `homelab.services.kopia.instances.mum.sources` includes `/mnt/backup/pfsense`.
- `modules/nixos/services/syncoid-pfsense.nix` — the systemd unit + timer + sanoid wiring + status JSON writer + benign-refusal masker.
- `modules/nixos/services/pfsense-backup-watchdog.nix` — hourly check of status JSON freshness + content canary (config.xml ≥ 50 KB).
- `secrets/hosts/doc2/syncoid-pfsense-key` — sops-encrypted ed25519 private key (doc2-only recipient in `.sops.yaml`).
- `secrets/hosts/doc2/syncoid-pfsense-key.pub` — public key (plain), registered with pfSense admin user.

### On prom (Debian 12 / Proxmox VE 8.x — NOT in this repo)

- `nvmeprom/vm-114-pfsense-backup` — 10 GB zvol attached as VM 114 virtio1. Created with:
  ```sh
  pvesm alloc nvmeprom 114 vm-114-pfsense-backup 10G
  zfs set compression=off primarycache=metadata sync=disabled \
    nvmeprom/vm-114-pfsense-backup
  qm set 114 --virtio1 nvmeprom:vm-114-pfsense-backup,size=10G,cache=none,discard=on
  ```

That's it. **All the imperative prom-side stuff** (syncoid wrapper, systemd units, sanoid.conf entry, NFS export, firewall rules, virtiofs share, pve directory mapping) **was retired on 2026-05-26**.

## Bootstrapping a fresh doc2 (one-off)

After the NixOS config has ZFS support deployed and the zvol is attached as virtio1:

```sh
# 1. Find the new disk's stable path (avoid /dev/vdb — not stable across boots)
ls -la /dev/disk/by-path/

# 2. Create the pool. The mountpoint MUST be /mnt/backup/pfsense so the
#    watchdog and kopia source paths resolve correctly.
sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off \
  -O mountpoint=/mnt/backup/pfsense \
  pfsensebackup /dev/disk/by-path/virtio-pci-0000:00:0b.0

# 3. Trigger the first syncoid run (TOFU-accepts pfSense's host key).
sudo systemctl start syncoid-pfsense.service
journalctl -u syncoid-pfsense.service -f

# Expected: ~80 sec initial pull of ~1.5 GB; subsequent runs are seconds.
# Status file: cat /mnt/backup/pfsense/.syncoid-status.json
# Watchdog: sudo systemctl start pfsense-backup-watchdog.service
#   Expected: "PFSENSE-BACKUP OK ... canary_bytes=~175000"
```

## Operations

### Run syncoid manually

```sh
ssh doc2 'sudo systemctl start syncoid-pfsense.service && journalctl -u syncoid-pfsense.service -f'
```

### Check the watchdog

```sh
ssh doc2 'sudo systemctl start pfsense-backup-watchdog.service && journalctl -u pfsense-backup-watchdog.service -n 5'
```

A healthy run logs: `PFSENSE-BACKUP OK finished_at=... duration_seconds=... canary_bytes=<size>`

### Browse the backed-up files

```sh
ssh doc2 'ls /mnt/backup/pfsense/ROOT/default/cf/conf/config.xml'
```

### Inspect a specific historical snapshot

Sanoid auto-pruned snapshots are named `syncoid_doc2_<date>-GMT<offset>`. To browse one:

```sh
ssh doc2 'zfs list -t snapshot -r pfsensebackup'
# Then clone:
ssh doc2 'sudo zfs clone pfsensebackup/ROOT/default@<snapname> pfsensebackup/scratch-inspect'
```

### Force a fresh full pull (discard target state)

If snapshot chains get out of sync. Destroy + repull. doc2 doesn't need any virtiofs shenanigans this time around — just nuke the pool data and let syncoid recreate it.

```sh
ssh doc2 '
  sudo systemctl stop syncoid-pfsense.timer
  sudo zfs destroy -r pfsensebackup
  sudo zpool destroy pfsensebackup
  # Recreate the pool exactly as in the bootstrap section above
  sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off \
    -O mountpoint=/mnt/backup/pfsense \
    pfsensebackup /dev/disk/by-path/virtio-pci-0000:00:0b.0
  sudo systemctl start syncoid-pfsense.timer
  sudo systemctl start syncoid-pfsense.service
'
```

Expect ~80s for the ~1.5 GB full pull on LAN. Status file should show `ok: true, exit_code: 0` after; the watchdog reports `PFSENSE-BACKUP OK` on its next tick.

## Monitoring

The watchdog on doc2 fires hourly. It checks:

- Status file exists at `/mnt/backup/pfsense/.syncoid-status.json`.
- File mtime is within `maxAgeHours` (default 26h, so any miss of the daily 03:00 run pages by morning).
- JSON `exit_code` is 0 and `ok` is true.
- **Canary file** `/mnt/backup/pfsense/ROOT/default/cf/conf/config.xml` exists and is ≥ 50 KB. This catches the 2026-05-26 incident class: syncoid claims success and the status JSON looks fine, but the actual data tree is inaccessible (the failure mode that virtiofs+NFS gave us for 2 days).

On failure: emits `PFSENSE-BACKUP FAIL reason=<reason> ...` to journald → Loki → matched by `homelab.monitoring.errorPatterns` → alert-bridge re-shapes through claude → Gotify push.

**Loki queries:**

```logql
# All watchdog runs
{host="doc2", unit="pfsense-backup-watchdog.service"}

# Just failures (would match the alert too)
{host="doc2", unit="pfsense-backup-watchdog.service"} |~ "PFSENSE-BACKUP FAIL"

# syncoid runs (success or failure)
{host="doc2", unit="syncoid-pfsense.service"}
```

**Failure modes the watchdog catches:**

| reason= | What's likely broken |
|---|---|
| `status-file-missing` | The pool isn't mounted, or syncoid hasn't run yet. Check `zfs list pfsensebackup` and `systemctl status syncoid-pfsense.service`. |
| `status-file-stale` | syncoid timer hasn't run in >26h. `systemctl status syncoid-pfsense.timer`. Doc2 down? Timer failed? |
| `last-run-failed` | syncoid ran but exited non-zero AND the wrapper masker didn't catch it as benign. `journalctl -u syncoid-pfsense.service` for details. Likely: network blip to pfSense, ZFS send/recv stream error, SSH key reject, sanoid pruning conflict. |
| `canary-missing` | The cf/conf dataset isn't mounted OR config.xml was destroyed. Almost impossible with native ZFS — `zfs list -r pfsensebackup` should show all children. |
| `canary-too-small` | config.xml exists but is empty/truncated. Investigate manually — possibly a partial replication. |

## Known footguns

### Initial syncoid pull always returns rc=2 — masked

syncoid prints `CRITICAL ERROR: Target pfsensebackup exists but has no snapshots matching with pfSense! Replication to target would require destroying existing.` on the **wrapping** dataset. Every CHILD dataset still replicates cleanly. The wrapper in `modules/nixos/services/syncoid-pfsense.nix` detects this exact phrase and masks `rc=2 → 0`. Same logic as the retired prom script. Don't remove the masker without verifying that the underlying syncoid behaviour has changed — historically every fleet rebuild has hit this.

### writeShellApplication implicit `set -euo pipefail`

The module's wrapper script explicitly disables `errexit` and `pipefail` around the syncoid invocation. Without that, syncoid's rc=2 would kill the script before the masker could run — the status JSON wouldn't be written and the watchdog would correctly fail. Don't simplify this without thinking it through.

### JSON status file uses `jq -n` for escaping

The `last_error` field carries syncoid's CRITICAL output verbatim, which contains literal tabs and newlines. A hand-written heredoc produces invalid JSON. The wrapper uses `jq -n --arg` for every field to handle escaping. Hit on 2026-05-26 first deploy.

### `boot.zfs.extraPools` triggers a per-pool import unit

`zfs-import-pfsensebackup.service` runs at every boot and fails if the pool is missing. That's a single-unit failure, not a boot blocker, but it WILL light up systemd as "degraded." On first deploy before bootstrap, it fails. After bootstrap it succeeds forever. To rebuild from scratch (pool wiped), the first boot after `zpool destroy` will show the failure again until you recreate the pool.

### prom firewall expects NFS clients, NOT a tower-style "give me ZFS via NFS" trap

`/etc/pve/local/host.fw` on prom contains explicit accept rules for the NFS Music export clients (tower/epi/fra/wsl). Doc2's 192.168.1.35 was added briefly during the failed NFS-cutover and removed on 2026-05-26. If you ever want NFS again from prom → some new client, you need to re-add the rule set.

### Tower (Unraid) uses NFSv3 for the Music share — different fsid semantics

The Music export's `fsid=0` was removed on 2026-05-26 to let nfs-utils auto-generate the pseudo-root at `/`. Tower mounts Music with `vers=3` which doesn't use the NFSv4 pseudo-root at all, so the removal is invisible to tower. The NixOS clients (`modules/nixos/services/mounts/nfs-music.nix`) now mount the full path `192.168.1.12:/nvmeprom/containers/Music` (was `192.168.1.12:/`). If you ever re-add `fsid=0` to *anything* on prom, audit every NFSv4 client mount string first.

## When to revisit

- If syncoid runtime ever exceeds 5 minutes on the daily timer, investigate. Initial pulls aside, daily incrementals should be MB-scale and complete in <30s.
- If pool fragmentation on `pfSense` (the source pool on the firewall) climbs over 75%, consider a scheduled offline `zpool scrub` and `zpool replace` to a fresh SSD — Protectli's mSATA isn't infinite-write-endurance.
- If the zvol fills (currently 1.7 GB used of 10 GB, syncoid retention keeps snapshots), grow it:
  ```sh
  ssh root@192.168.1.12 'zfs set volsize=20G nvmeprom/vm-114-pfsense-backup'
  ssh doc2 'sudo zpool online -e pfsensebackup /dev/disk/by-path/virtio-pci-0000:00:0b.0'
  ```
- We deliberately do NOT have a second kopia destination for pfsense backup. Earlier the chain shipped to both kopia-photos (Wasabi) and kopia-mum (Synology); on 2026-05-26 we dropped the Wasabi copy — appliance backups don't fit the photos bucket's economics. If a dedicated Wasabi bucket gets stood up for fleet-state backups, the kopia source list can include `/mnt/backup/pfsense` there too. Until then: single off-site copy via mum.
