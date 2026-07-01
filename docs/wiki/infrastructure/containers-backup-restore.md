# prom nvmeprom/containers — off-box backup + restore runbook

**Date:** 2026-07-01 · **Status:** automated weekly service running (doc1 `containers-backup.service`); restore procedure documented, not yet drill-tested end-to-end.  
**Closes:** GitHub issue **#268** (containers offsite backup).

---

## TL;DR — what is backed up and where

Weekly age-encrypted tar archive of prom's `nvmeprom/containers` ZFS dataset (service-state for all doc1/doc2 homelab services). Lands on tower, then shipped offsite to mum's Synology via kopia-mum on doc2.

| | |
|---|---|
| **Service** | `containers-backup.service` on doc1 (weekly Wednesdays 03:30 AWST) |
| **Tower** | `/mnt/user/VMBackups/containers/containers-backup-YYYY-MM-DD.tar.gz.age` |
| **Sidecar** | `…/containers-backup-YYYY-MM-DD.tar.gz.age.sha256` |
| **Offsite** | kopia-mum on doc2 → mum's Synology (`/mnt/mum`); source: `/mnt/backup/vm-backups/containers` (tower NFS RO) |
| **Encryption** | age (ChaCha20-Poly1305 AEAD); break-glass key (Bitwarden) OR doc1 editor key |
| **Count kept on tower** | 4 most-recent; oldest auto-pruned |

---

## What is — and is NOT — included

**IN (by default):** everything under `nvmeprom/containers` that isn't explicitly excluded:
- `atuin`, `audiobookshelf`, `beancount`, `cratedigger`, `forgejo`, `gotify`, `immich`, `jellyfin` (jellystat only), `jdownloader2`, `kopia`, `komga`, `mailarchive`, `mealie`, `musicbrainz`, `overseerr`, `paperless`, `slskd` (config, not downloads), `tautulli`, `uptime-kuma`, `watchstate`, `youtarr`, and any new service added in future.

**NOT IN (opt-out exclusions in `modules/nixos/services/containers-backup.nix`):**

| Dir | Reason |
|---|---|
| `Music` | NFS re-export from tower — not ours to back up |
| `music` | Old Lidarr-managed library — large media, not config |
| `kopia` | Kopia's own repo data — already backed up off-site |
| `jellyfin` | Thumbnails/metadata cache — fully regeneratable |
| `loki` | Log data — ephemeral |

New services added to `/nvmeprom/containers` are **automatically included** without any config change. Add to `cfg.excludeDirs` to explicitly opt out.

---

## Encryption

Archives are encrypted **in flight on doc1** using `age -e` before writing to tower. Two decryption keys exist:

| Key | Location |
|---|---|
| **doc1 editor key** | `~/.config/sops/age/keys.txt` on doc1 |
| **break-glass key** | Bitwarden vault + printed copy |

---

## Restore — decrypt and extract

From doc1 (which has the editor key):

```sh
# List available backups on tower:
ssh root@tower "ls -lht /mnt/user/VMBackups/containers/"

# Fetch and decrypt to a local tar stream:
ssh root@tower "cat /mnt/user/VMBackups/containers/containers-backup-YYYY-MM-DD.tar.gz.age" \
  | age -d -i ~/.config/sops/age/keys.txt \
  | tar -tzf -   # list contents

# Restore to a target directory (e.g. a fresh mount at /mnt/restore):
ssh root@tower "cat /mnt/user/VMBackups/containers/containers-backup-YYYY-MM-DD.tar.gz.age" \
  | age -d -i ~/.config/sops/age/keys.txt \
  | tar -xzf - -C /mnt/restore/
```

If doc1 is unavailable, use the break-glass key from Bitwarden:
```sh
age -d -i /path/to/breakglass-key.txt containers-backup-YYYY-MM-DD.tar.gz.age | tar -xzf - -C /mnt/restore/
```

### Restoring to a live ZFS dataset

The snapshot was taken as `nvmeprom/containers@containers-backup-YYYY-MM-DD`. The tar contents are a snapshot of the dataset at that point. To restore specific service dirs:

```sh
# Stop the service:
ssh doc2 "sudo systemctl stop paperless-ngx.service"
# Restore just that service's dir:
ssh root@tower "cat .../containers-backup-YYYY-MM-DD.tar.gz.age" \
  | age -d -i ~/.config/sops/age/keys.txt \
  | tar -xzf - -C /nvmeprom/containers/ ./paperless
# Restart:
ssh doc2 "sudo systemctl start paperless-ngx.service"
```

---

## Checking current backup status

From doc1:
```sh
# Latest backup on tower:
ssh root@tower "ls -lht /mnt/user/VMBackups/containers/ | head -5"

# Last run status (exit code, duration, error):
sudo cat /var/lib/containers-backup/.status.json | jq .

# Service logs:
journalctl -u containers-backup.service -n 50

# Timer:
systemctl status containers-backup.timer

# Watchdog (checks status file age daily):
systemctl status containers-backup-watchdog.timer
```

---

## How this backup works

The `containers-backup.service` on doc1 runs weekly on Wednesdays at 03:30 AWST. Steps:

1. `zfs snapshot nvmeprom/containers@containers-backup-YYYY-MM-DD` (on prom, atomic)
2. `tar -C /nvmeprom/containers/.zfs/snapshot/<tag>/ … -czf - . | age -e -r <breakglass> -r <editor> | cat > tower:.tar.gz.age.tmp`
3. Rename .tmp → final; write sha256 sidecar
4. Write `/var/lib/containers-backup/.status.json`
5. `zfs destroy nvmeprom/containers@<tag>` (non-fatal; snapshot served its purpose)
6. Prune tower to keep 4 most recent `.tar.gz.age` files

Source: `modules/nixos/services/containers-backup.nix`. Enabled in `hosts/proxmox-vm/configuration.nix`.

**Reuses** the same SSH key as prom-rpool-backup (`prom-rpool-backup/key` sops secret, `from="192.168.1.29"` restriction on prom).

Manual re-run from doc1: `sudo systemctl start containers-backup.service`

---

## Offsite via kopia-mum (doc2)

Doc2's kopia-mum instance backs up `/mnt/backup/vm-backups/containers` (a lazy NFS mount of tower's `VMBackups` share) to mum's Synology. The encrypted `.tar.gz.age` files are backed up as opaque blobs — kopia deduplicates and retains per its snapshot policy.

**Prerequisite (tower Unraid):** enable NFS export of the `VMBackups` share, read-only, scoped to `192.168.1.35` and `192.168.1.36` (doc2's two NICs). See Settings → NFS → enable shares, then `VMBackups` share → NFS export → RO, `192.168.1.35/32 192.168.1.36/32`.

The NFS mount on doc2 is lazy (`x-systemd.automount`, `nofail`) — a temporarily down tower doesn't block doc2 boot or activation. A missed kopia backup due to tower being offline just means that week's snapshot isn't offsite; the next kopia run catches it.

To verify the offsite copy is current: check `kopiamum.ablz.au` in the browser or `sudo kopia snapshot list` as root on doc2.

---

## Verification

```sh
# Verify sha256 of encrypted blob on tower:
ssh root@tower "cd /mnt/user/VMBackups/containers && sha256sum -c containers-backup-YYYY-MM-DD.tar.gz.age.sha256"

# Test decrypt and list archive (confirms age AEAD + gzip stream integrity):
ssh root@tower "cat containers-backup-YYYY-MM-DD.tar.gz.age" \
  | age -d -i ~/.config/sops/age/keys.txt \
  | tar -tzf - | wc -l
```

`age -d` failure = ciphertext corruption or wrong key. `tar -tzf` error after decryption = gzip/tar corruption. Both caught before you need to actually restore.
