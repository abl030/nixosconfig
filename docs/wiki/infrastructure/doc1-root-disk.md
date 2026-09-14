# Doc1 root disk

**Date:** 2026-09-15

**Status:** Live; expanded online from 500 GiB to 600 GiB.

## Disk identity and expansion

Doc1 (`proxmox-vm`) is VM **104**, named `Doc1`, on `prom`. Its boot disk is
`scsi0`, backed by `nvmeprom:vm-104-disk-1`. In the guest this is `/dev/sda`:
512 MiB EFI partition `/dev/sda1`, then ext4 root `/dev/sda2`. There is no LVM.
Verify these identities and backing-pool headroom again before another resize.

On 2026-09-15 the root filesystem was 93% used, with about 35 GiB available.
The following sequence completed without a reboot:

1. Saved the guest partition table with `sfdisk --dump /dev/sda` and the
   Proxmox configuration `/etc/pve/qemu-server/104.conf`. Backups are under
   `/root/doc1-disk-expansion-20260915/` on their respective hosts.
2. On prom, ran `qm disk resize 104 scsi0 600G`. Use an absolute target size
   so retrying the command cannot add another increment.
3. Verified that the guest saw 644245094400 bytes for `/dev/sda`.
4. On doc1, inspected `sudo growpart -N /dev/sda 2`, then ran
   `sudo growpart /dev/sda 2` and `sudo resize2fs /dev/sda2`.
5. Verified the partition start remained sector 1050624 and root grew to
   157155067 filesystem blocks of 4096 bytes. `df -h /` showed 590 GiB usable
   filesystem size, 434 GiB used, 129 GiB available, and 78% usage.

The kernel logged a successful ext4 resize, systemd reported no failed units,
and both Nix cache endpoints and Forgejo's version endpoint returned successfully.
This is Proxmox and on-disk state; it requires no NixOS rebuild. Do not shrink
the virtual disk or restore the old partition table after growing the filesystem.

## Space investigation

These are allocated-space observations from the same session, not permanent
capacity targets. The audit used `du -x` to exclude virtiofs and NFS data.

- `/nix`: **157.5 GiB**, the Nix store and its database.
- `/var/cache/nginx-nix-mirror`: **106.5 GiB**, almost entirely stored NARs.
  The deployed prune script uses 45-day access-time retention and has no byte
  limit. Daily pruning succeeded; a read-only age scan found 62.3 GiB matching
  `find -atime +14` and 34.6 GiB matching `find -atime +30`.
- `/var/lib/docker`: **52.2 GiB**, mostly old overlay layers. Docker service
  and socket were absent; stored containers mostly last stopped in January.
- `/var/lib/containers`: **13.1 GiB**, mostly old Podman overlay layers. Neither
  runtime was installed, Podman's stored container list was empty, and no
  overlay filesystems were mounted on doc1.
- `/home/abl030`: **61.9 GiB**, including 14.2 GiB in `.cache`, 11.5 GiB in
  `.claude`, and 4.8 GiB in `.codex`. The largest identified cache was `uv`
  at 9.2 GiB; `.claude/jobs` held 9.1 GiB.
- `/var/lib/swapfile`: **24 GiB**, deliberately configured emergency swap.
- `/var/crash`: **9.6 GiB**, including an 8 GiB crash-capture reserve.
- `/var/log`: **4.1 GiB**, mainly the system journal.

Nix garbage collection succeeded at 03:33 AWST, deleting 40,064 store paths
and freeing 34.4 GiB. Deleted-but-open files accounted for only 4 KiB.
No cleanup was performed: the request was to add headroom and then discuss
usage. Revisit the old container layers and mirror retention first; verify
that candidate data is still unused before deleting it.
