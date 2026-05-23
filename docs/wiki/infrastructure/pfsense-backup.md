# pfSense backup architecture

**Date built:** 2026-05-23
**Status:** Live. First scheduled syncoid run: 2026-05-24 03:00 AWST.
**Related:** [pfsense-dns-resolver](pfsense-dns-resolver.md), [dns-saturation-incident-2026-05-22](dns-saturation-incident-2026-05-22.md).

## TL;DR

Three-layer defence in depth for the bare-metal pfSense firewall (Protectli FW4C, ZFS-on-root, 30 GB SSD):

1. **AutoConfigBackup (ACB)** — Netgate's hosted config-only service. Encrypted client-side, off-site, triggers on every config save. ~32 days history. Password lives in Bitwarden.
2. **ZFS replication to prom** — syncoid daily pulls the full pool (minus ntopng's telemetry) to `nvmeprom/backup/pfsense`. ~1.5 GB initial, KB-MB-scale incrementals. Sanoid retention 30 daily / 8 weekly / 6 monthly.
3. **Kopia off-site replication** — doc2 mounts the replicated dataset RO via virtiofs and ships it to **both** mum's Synology (over Tailscale) and Wasabi (Object Lock) as belt-and-braces.

A doc2-side watchdog reads the JSON status file syncoid writes on every run and routes failures through `homelab.monitoring.errorPatterns` → alert-bridge → Gotify.

## Architecture

```
   ┌──────────────────────────────────────────────────────────────┐
   │  pfSense (Protectli FW4C, bare metal, ZFS-on-root pool       │
   │   named "pfSense")                                            │
   │                                                                │
   │   ntopng's bulk telemetry isolated to its own dataset        │
   │   so syncoid can exclude it cleanly.                          │
   │                                                                │
   │   SSH access for syncoid is restricted via authorized_keys    │
   │   forced-command wrapper at /root/.ssh/syncoid-wrapper.sh     │
   │   (only zfs ops + echo probe).                                │
   └────────────────────────┬─────────────────────────────────────┘
                            │  syncoid (pull, daily 03:00 AWST)
                            │  ed25519 key + forced-command
                            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  prom (Proxmox 8.x, ZFS host 192.168.1.12)                    │
   │                                                                │
   │   nvmeprom/backup/pfsense  ← syncoid -R -- --exclude=ntopng   │
   │     ├─ ROOT/default        (OS + config, ~1.4 GB)             │
   │     ├─ ROOT/default/cf     (config.xml, ~2 MB)                │
   │     ├─ var/db              (kea, tailscale, pfblockerng)      │
   │     └─ ...                                                     │
   │   .syncoid-status.json     ← wrapper writes per run            │
   │                                                                │
   │   Sanoid: autoprune-only (autosnap=no). 30d / 8w / 6m.        │
   │   Sanoid runs every 15min via systemd timer.                  │
   │                                                                │
   │   virtiofs share dirid=pfsense-backup, mapped to               │
   │   /nvmeprom/backup/pfsense on prom.                            │
   └────────────────────────┬─────────────────────────────────────┘
                            │  virtiofs (ro from doc2 perspective)
                            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  doc2 (NixOS VM 114 on prom)                                  │
   │                                                                │
   │   /mnt/pfsense-backup  ← virtiofs RO                          │
   │     └─ .syncoid-status.json                                   │
   │                                                                │
   │   pfsense-backup-watchdog.timer (hourly): reads status,       │
   │     emits "PFSENSE-BACKUP FAIL ..." on stale/red.             │
   │                                                                │
   │   Kopia sources include /mnt/pfsense-backup in BOTH:          │
   │     - kopia-photos (Wasabi Object Lock)                       │
   │     - kopia-mum (mum's Synology over Tailscale)               │
   └────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
                    Wasabi  +  Synology
                  (two independent off-site copies)
```

## What's covered (and what's not)

| Layer | Captures | Doesn't capture |
|---|---|---|
| ACB | `config.xml` (every rule, NAT, VPN, CA, DHCP, DNS settings) | Package binaries, RRD data, lease databases, certificates not in config.xml |
| ZFS replication | Everything in `pfSense/ROOT/*`, `pfSense/var/db`, `pfSense/var/log`, etc. — including installed packages, kea leases, Tailscale identity, pfBlockerNG state | `pfSense/var/db/ntopng` (intentionally excluded — disposable telemetry) |
| Kopia | Whatever the ZFS replication carried, off-site | Same exclusions |

The ZFS path captures the **identical** package versions and binary state, which is what makes the SSD-restore path so fast: no pfSense reinstall, no `pkg install pfBlockerNG-devel`, no `kea2unbound` reload storm. Restore is byte-for-byte the firewall you had.

## Recovery procedures

### Scenario 1: fat-finger config rollback

You broke a firewall rule and want to undo. Don't restore from this stack — ACB has 32 days of per-config-save snapshots and the GUI restore is the right tool.

**Procedure:** pfSense GUI → Diagnostics → Backup & Restore → AutoConfigBackup tab → pick a snapshot → restore. <5 minutes.

### Scenario 2: SSD failure, identical Protectli still working

The mSATA died but the box is fine. You have the ZFS replica on prom.

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
4. From a network-accessible shell on the new pfSense (or via temporary network on the installer), receive the latest snapshot from prom:
   ```sh
   # Find latest syncoid snap on prom:
   ssh root@192.168.1.12 'zfs list -H -t snapshot -o name -s creation -r nvmeprom/backup/pfsense | tail -1'
   # Then on the new pfSense (over SSH from prom is easier — pull via ssh):
   ssh root@192.168.1.12 \
     'zfs send -R nvmeprom/backup/pfsense@<latest>' \
     | zfs receive -F pfSense
   ```
5. Set bootfs: `zpool set bootfs=pfSense/ROOT/default pfSense`
6. Install the FreeBSD bootloader to ada0:
   ```sh
   gpart bootcode -p /boot/boot1.efifat -i 1 ada0
   ```
7. Reboot. pfSense should come up byte-identical to the donor.

RTO: ~20-30 min.

### Scenario 3: full Protectli failure, no spare

You need a working firewall and the hardware is gone. Use prom as a temporary firewall.

**Procedure (the "VM on prom" play, design-documented for this exact case):**

1. Create a new VM on prom with the Protectli's profile:
   - UEFI boot
   - Add a second NIC passed through for WAN
   - 4 GB RAM, 2 cores
2. **Clone the backup dataset to a VM disk:**
   ```sh
   zfs clone nvmeprom/backup/pfsense@<latest> nvmeprom/vm-NNN-pfsense
   ```
   ...then attach as the VM's root disk.
3. Boot. The pfSense console will prompt to reassign interfaces — the NIC names changed (igc0 → vtnet0). Walk through the prompt.
4. Adjust WAN/LAN assignments in the GUI as needed.

RTO: ~20-30 min once you've got the second NIC passed through.

This is a temporary fix until new Protectli hardware arrives — pfSense Plus has hardware-NDI licensing concerns that don't apply to CE (which is what we run), but running production WAN through a hypervisor permanently is not the goal.

### Scenario 4: full house loss

Everything on-prem is gone. Recovery from cloud:

1. New hardware (Protectli or any UEFI-capable mini-PC).
2. Fresh pfSense install from ISO.
3. Restore config from **ACB** via the installer's "Recover config from backup" option (you'll need the encryption password from Bitwarden).
4. If pfBlockerNG fails to re-initialise cleanly (it sometimes does — known Redmine bugs), pull `/var/db/pfblockerng/` and `/usr/local/etc/pfblockerng/` from Kopia and drop them in.
5. Tailscale re-auth is required regardless (identity isn't preserved across an ACB-only restore).

RTO: ~1-2 hours assuming hardware on hand. Days if shipping.

## Components and where they live

### On pfSense (FreeBSD; persistent across reboots via pfSense config.xml reconciliation)

- `/root/.ssh/syncoid-wrapper.sh` — forced-command wrapper restricting the syncoid key to `zfs ` and `echo ` commands. This file is **not** managed by pfSense config.xml — it's a raw file that survives reboots independently.
- `/root/.ssh/authorized_keys` — managed via the pfSense user API (config.xml `<authorizedkeys>` field). Contains the syncoid-from-prom ed25519 public key with `command="/root/.ssh/syncoid-wrapper.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,no-user-rc` options.

### On prom (Debian 12 / Proxmox VE 8.x — NOT in this repo, configured manually)

- `/usr/local/sbin/syncoid-pfsense.sh` — wrapper that runs syncoid, writes JSON status file.
- `/etc/systemd/system/syncoid-pfsense.service` — oneshot.
- `/etc/systemd/system/syncoid-pfsense.timer` — daily 03:00 AWST.
- `/etc/sanoid/sanoid.conf` — retention policy for the receiver.
- `/etc/pve/mapping/directory.cfg` — directory mapping `pfsense-backup` → `/nvmeprom/backup/pfsense`.
- `/etc/pve/qemu-server/114.conf` — doc2 VM config with `virtiofs2: dirid=pfsense-backup,cache=auto`.
- `/root/.ssh/id_ed25519_syncoid_pfsense{,.pub}` — dedicated keypair for the syncoid pull.

If prom is rebuilt from scratch, all of the above needs reconstructing. See the "Rebuild prom side" section below for the full set.

### On doc2 (NixOS — declarative, in this repo)

- `hosts/doc2/configuration.nix` — `fileSystems."/mnt/pfsense-backup"` virtiofs RO mount + `homelab.services.pfsenseBackupWatchdog.enable = true` + adds `/mnt/pfsense-backup` to both kopia instances' `sources`.
- `modules/nixos/services/pfsense-backup-watchdog.nix` — the watchdog module + auto-wired errorPatterns alert.

## Rebuild prom side from scratch

Should prom ever be reinstalled or moved, redo this sequence:

```sh
# 1. Install sanoid + syncoid
apt install -y sanoid

# 2. Create destination dataset PARENT only — do NOT pre-create
#    nvmeprom/backup/pfsense itself. Let syncoid create the wrapper
#    as part of the recursive replication. Pre-creating it causes
#    syncoid to refuse forever ("Cowardly refusing to destroy your
#    existing target") because the hand-created wrapper has no
#    snapshot matching the source pool. See "Known footguns" →
#    "Initial `zfs create` of the target was suboptimal" for the
#    2026-05-24 incident this caused.
zfs create -o compression=lz4 -o atime=off nvmeprom/backup

# 3. Generate keypair (ed25519, no passphrase)
ssh-keygen -t ed25519 -N "" \
  -f /root/.ssh/id_ed25519_syncoid_pfsense \
  -C "syncoid-from-prom-to-pfsense"

# 4. Install the public key on pfSense via the GUI (System → User Manager → admin →
#    Authorized SSH Keys) — paste the contents of id_ed25519_syncoid_pfsense.pub
#    PREPENDED with: command="/root/.ssh/syncoid-wrapper.sh",no-port-forwarding,
#    no-X11-forwarding,no-agent-forwarding,no-pty,no-user-rc
#    Then SSH into pfSense and create /root/.ssh/syncoid-wrapper.sh with the
#    content documented above.

# 5. Write /etc/sanoid/sanoid.conf:
cat > /etc/sanoid/sanoid.conf <<'EOF'
[nvmeprom/backup/pfsense]
    use_template = pfsense_backup
    recursive = yes
    process_children_only = no

[template_pfsense_backup]
    hourly = 0
    daily = 30
    weekly = 8
    monthly = 6
    yearly = 0
    autosnap = no
    autoprune = yes
EOF

# 6. Write the syncoid wrapper script. See the actual file on prom for the
#    canonical content — paraphrased: runs syncoid with --exclude=ntopng,
#    captures stdout+exit-code, writes JSON status file to
#    /nvmeprom/backup/pfsense/.syncoid-status.json.

# 7. Write the systemd unit + timer. Daily at 03:00.

# 8. Add the virtiofs directory mapping to /etc/pve/mapping/directory.cfg:
cat >> /etc/pve/mapping/directory.cfg <<'EOF'

pfsense-backup
	map node=prom,path=/nvmeprom/backup/pfsense
	description pfSense ZFS-replicated backup target (RO consumer mount)
EOF

# 9. Attach the share to doc2 (VM 114) — requires VM stop/start to take effect:
qm set 114 -virtiofs2 dirid=pfsense-backup,cache=auto

# 10. Test the initial pull:
syncoid --recursive \
  --exclude="pfSense/var/db/ntopng" \
  --sshkey=/root/.ssh/id_ed25519_syncoid_pfsense \
  root@192.168.1.1:pfSense nvmeprom/backup/pfsense
```

## Operations

### Run syncoid manually

```sh
ssh root@192.168.1.12 'systemctl start syncoid-pfsense.service && journalctl -u syncoid-pfsense.service -f'
```

### Check the watchdog from doc2

```sh
ssh doc2 'sudo systemctl start pfsense-backup-watchdog.service && journalctl -u pfsense-backup-watchdog.service -n 5'
```

### Browse the backed-up files

From doc2 (read-only):
```sh
ls /mnt/pfsense-backup/ROOT/default/cf/config.xml  # The latest config.xml
```

From prom (read-write — be careful, don't edit):
```sh
ls /nvmeprom/backup/pfsense/ROOT/default/cf/
```

### Force a fresh full pull (discard target state)

If snapshot chains get out of sync (rare), nuke and start over.

**Critical:** `zfs destroy -r` on the wrapper will fail while doc2's
virtiofs share is open (`pool or dataset is busy`). And worse — the
destroy is partially atomic: it destroys all CHILD SNAPSHOTS first,
then errors on the busy mount. You're left with empty target datasets
and no common ancestor — every subsequent run fails with "no snapshots
matching." Always shut doc2 down first.

After destroy, do NOT pre-create `nvmeprom/backup/pfsense` — let
syncoid build the wrapper itself so it gets a proper snapshot base.

```sh
# 1. Stop doc2 to release virtiofsd handles on the share.
ssh root@192.168.1.12 'qm shutdown 114 --timeout 60 && qm status 114'

# 2. Destroy + re-pull from source. (Note: NO `zfs create` after destroy.)
ssh root@192.168.1.12 '
  zfs destroy -r nvmeprom/backup/pfsense
  systemctl start syncoid-pfsense.service
  cat /nvmeprom/backup/pfsense/.syncoid-status.json
'

# 3. Bring doc2 back; virtiofs reattaches at VM start.
ssh root@192.168.1.12 'qm start 114'
```

Expect ~1-2 min downtime on doc2 and ~30-90s for the ~1.5GB pull on
LAN. The status file should show `ok: true, exit_code: 0` afterwards;
the doc2 watchdog reports `PFSENSE-BACKUP OK` on its next tick.

### Inspect a specific historical snapshot

Sanoid's auto-pruned snapshots are named `syncoid_prom_<date>-GMT<offset>`. To browse one:

```sh
ssh root@192.168.1.12 '
  zfs list -t snapshot -o name nvmeprom/backup/pfsense/ROOT/default
  # Then clone it to a temporary read-only spot:
  zfs clone nvmeprom/backup/pfsense/ROOT/default@<snapname> tank/scratch/inspect
'
```

## Monitoring

The watchdog on doc2 fires hourly. It checks:
- Status file exists at `/mnt/pfsense-backup/.syncoid-status.json`.
- File mtime is within `maxAgeHours` (default 26h, so any miss of the daily 03:00 run pages by morning).
- The JSON's `exit_code` is 0 and `ok` is true.

On failure: emits `PFSENSE-BACKUP FAIL reason=<reason> ...` to journald → Loki → matched by `homelab.monitoring.errorPatterns` → alert-bridge re-shapes through claude → Gotify push.

The watchdog also recognises the "placeholder" state (the JSON file written before the first scheduled syncoid run) and treats it as informational, not failure.

**Loki queries:**

```logql
# All watchdog runs
{host="doc2", unit="pfsense-backup-watchdog.service"}

# Just failures (would match the alert too)
{host="doc2", unit="pfsense-backup-watchdog.service"} |~ "PFSENSE-BACKUP FAIL"
```

**Failure modes the watchdog catches:**

| reason= | What's likely broken |
|---|---|
| `status-file-missing` | virtiofs share isn't mounted, or prom hasn't written one yet. Check `mount \| grep pfsense-backup` on doc2 and check prom's syncoid timer ran. |
| `status-file-stale` | prom's syncoid timer hasn't run in >26h. Check `systemctl status syncoid-pfsense.timer` on prom — host down? Timer failed? |
| `last-run-failed` | syncoid ran but exited non-zero. `journalctl -u syncoid-pfsense.service` on prom for details. Could be: network blip to pfSense, ZFS send/recv stream error, SSH key reject, sanoid pruning conflict. |

## Known footguns

### `nvmeprom/backup/pfsense` is the WRAPPING dataset, not the data

The actual replicated data lives in *children* (`nvmeprom/backup/pfsense/ROOT/default`, etc.). The parent `nvmeprom/backup/pfsense` exists only to host the status file and the share point. **Do not `zfs destroy nvmeprom/backup/pfsense` without `-r`** — and if you `-r`, you've thrown the whole backup away. Sanoid's prune only ever removes individual snapshots, never datasets.

### Initial `zfs create` of the target was a BUG, not a warning — fixed 2026-05-24

**Original framing:** the first run from a hand-created target dataset prints `Cowardly refusing to destroy your existing target`. Believed harmless — syncoid proceeds with each child dataset replicating into its own newly-created child target. The wrapping dataset stays empty (just hosts the status file).

**Reality (discovered 2026-05-24):** syncoid exits with `rc=2` on every single run because the wrapper refuses. The doc2 watchdog reads `exit_code != 0` from the status JSON and pages every hour. Result: continuous alert flapping starting the very first scheduled run. The `homelab.monitoring.errorPatterns` route doesn't suppress it — `pfsense-backup-watchdog` is wired with `threshold = 0` (single-shot terminal) precisely because each watchdog tick logs the failure exactly once before exiting.

**Two-part fix in place:**

1. **Rebuild recipe** (above, step 2) no longer pre-creates `nvmeprom/backup/pfsense`. Only `nvmeprom/backup` is created. syncoid creates the wrapper itself during the first recursive replication and gets a proper snapshot base.

2. **Safety net in the syncoid wrapper script** (`/usr/local/sbin/syncoid-pfsense.sh` on prom): if syncoid exits 2 AND the LAST critical-level line in its output matches `Cowardly refusing to destroy your existing target`, the wrapper masks `rc` to 0 and prefixes `last_error` with `(masked benign wrapper refusal)`. This catches any future drift back into the pre-create state without re-triggering the alert storm.

**Incident detail (2026-05-24 morning):** the original watchdog noise was a sequence of warnings escalating to my own destructive intervention that made it worse. I ran `zfs destroy -r nvmeprom/backup/pfsense` while doc2's virtiofs share was holding the mounts open. The destroy is **partially atomic** — it destroyed every snapshot in the tree FIRST, then errored on the busy mounts. That left every child dataset with data but zero snapshots, breaking the incremental chain completely. Recovery required `qm shutdown 114` → destroy (now successful) → fresh full pull (NOT pre-creating) → `qm start 114`. ~2 min doc2 downtime, ~80s for the ~1.5GB initial pull on LAN. Total backup downtime: ~5 min.

**Lesson:** always shut doc2 down before any destructive operation on `nvmeprom/backup/pfsense` or its children. virtiofsd holds the shared-dir open as its root inode and won't release on `umount -f` — only VM shutdown drops the handle.

### virtiofs share changes require VM restart (qm stop + qm start, not `reboot`)

Adding/removing virtiofs entries on a running VM via `qm set` updates `/etc/pve/qemu-server/NNN.conf` but the running qemu process doesn't see the change. Doc2 needs `qm shutdown 114 && qm start 114` from prom (or equivalent) to attach a new share.

### Read-only is enforced at the doc2 mount layer, not at virtiofs

Proxmox's virtiofs config doesn't expose a `readonly` flag for the share itself. The RO contract is enforced via the `ro` mount option in doc2's `fileSystems` entry. A compromised doc2 with sufficient privilege could remount rw — but at that point you've lost. For accidental-write protection (the realistic threat), the mount-side `ro` is enough.

### Kopia source for `/mnt/pfsense-backup` requires the mount to exist before the kopia source-sync runs

If the virtiofs share is missing on first deploy, the kopia source-sync will register `/mnt/pfsense-backup` as a source but kopia itself will error when it tries to walk a non-existent path. The order matters: bring the virtiofs share in (VM restart) → deploy doc2 → kopia source-sync runs against a valid mount.

The mount carries `nofail` so a missing share won't block boot — but the watchdog AND kopia will both spit errors until the share is back.

## When to revisit

- If syncoid runtime ever exceeds 5 minutes on the daily timer, investigate. Initial pulls aside, daily incrementals should be MB-scale and complete in <30s.
- If pool fragmentation on `pfSense` (the source pool) climbs over 75%, consider a scheduled offline `zpool scrub` and `zpool replace` to a fresh SSD — Protectli's mSATA isn't infinite-write-endurance.
- If we ever add a third kopia instance (e.g. for some new mission-critical data), do NOT add `/mnt/pfsense-backup` to it — two off-site copies are enough. The marginal value of a third copy is below the cost of the kopia config bloat.
- If we replace the Protectli with a Netgate appliance (Plus license), the SSD-restore path (Scenario 2) becomes complicated because Plus binds to NIC NDI. Re-read [pfsense-dns-resolver](pfsense-dns-resolver.md) and the research-agent's notes from the 2026-05-23 backup-design session.
