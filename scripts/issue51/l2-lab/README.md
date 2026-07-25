# L2 nested-seam lab (nixosconfig#51 experiment E4)

Reproduces doc2 -> slskd end-to-end, inside the isolated lab VM 951. Never touches
`/mnt/virtio`.

```
prom ZFS /nvmeprom/issue51-virtiofs-lab
  └─ prom virtiofsd (--inode-file-handles=prefer)  → VM951 /mnt/virtiofs   [= doc2 /mnt/virtio]
       └─ VM951 virtiofsd (--inode-file-handles=never) → L2 microVM /data  [= slskd guest]
```

`l2-guest.nix` builds the nested cloud-hypervisor microVM with the *same*
virtiofsd wrapper doc2 uses. `l2-harness.py` runs inside it. `l2-start.sh` brings
the stack up on VM951 under transient systemd units.

## Running

```sh
# on doc1
nix build --impure --expr 'import ./l2-guest.nix {}'
nix copy --to ssh://root@<lab-ip> ./result
scp l2-start.sh root@<lab-ip>:/root/
ssh root@<lab-ip> "/root/l2-start.sh <runner-store-path>"

# wait for _sync/READY, then from prom (the external writer):
cd /nvmeprom/issue51-virtiofs-lab/l2-scratch
for i in 0 2 4 6 8 10; do d=$(printf 'album-%03d' $i); rm -rf "$d"; mkdir "$d"; \
  dd if=/dev/zero of="$d/track.bin" bs=65536 count=1 status=none; done
sync && touch _sync/CHURNED

ssh root@<lab-ip> "journalctl -u l2-guest | grep L2H"
```

## Gotchas that cost time

- `systemd-run` gives a minimal PATH; the microvm virtiofsd wrapper needs `id`
  and `nproc`, so pass `--setenv=PATH=/run/current-system/sw/bin`.
- virtiofsd serves a single vhost-user connection. If the VM fails to boot, the
  daemons must be restarted before retrying or you get `ConnectionRefused`.
- The lab VM's serial socket does not deliver to a socat reader; use netconsole
  (`lab-netconsole`, receiver `vm951-netconsole-recv` on prom) for kernel output.
