# slskd microVM cage

**Built:** 2026-07-19 · **Status:** deployed and accepted · **Tracking:** Forgejo [#38](https://git.ablz.au/abl030/nixosconfig/issues/38) (closed)

slskd parses Internet peer traffic and accepts the USA AirVPN `45727` forward. It therefore runs in a dedicated `microvm.nix` / cloud-hypervisor guest instead of doc2's host namespace. The configuration is `hosts/doc2/slskd-microvm.nix`.

**2026-07-22 stability mitigation:** two outer doc2 kernel panics after cutover implicated Cloud Hypervisor's `_net0_qp2` worker. slskd is now fixed at two vCPUs/four network queues, matching the stable qbt cage and removing `qp2`/`qp3`. Doc1 independently captures netconsole/VGA evidence and resets only after sustained dual-path failure. See [the full RCA hypothesis and recovery design](../infrastructure/doc2-kernel-panic-2026-07-22.md).

## Boundary

The guest is `192.168.21.2` on the single-tenant VLAN 21 `SLSKD_DMZ`.
doc2's Proxmox VMID 114 has a third vNIC (`net2`) tagged VLAN 21; doc2
bridges that IP-less `ens20` uplink to the guest tap. doc2 never takes a DMZ
address. A separate VLAN is load-bearing: hosts in one IP subnet exchange
frames directly, so a pfSense rule cannot isolate two peers on the same VLAN.

pfSense is the boundary, not the guest:

1. SLSKD_DMZ permits DNS only to `192.168.21.1:53`, then blocks the complete `RFC1918` alias.
2. Remaining egress is policy-routed through `AIRVPN_US_PREFERRED` (USA tier 1, Netherlands tier 2), followed by a terminal block. There is no WAN member.
3. LAN permits only doc2 `192.168.1.35` to the guest API `192.168.21.2:5030`, followed immediately by a general LAN-to-SLSKD_DMZ block.
4. USA AirVPN `45727/tcp+udp` translates to `192.168.21.2:50300`, with a separate explicit USA-interface pass rule. Netherlands has no inbound forward.

Soulseek/slskd itself listens on TCP. The AirVPN assignment and pfSense forward retain both TCP and UDP, but an idle UDP socket is not fabricated merely to satisfy a port scan; verify the real TCP listener and the configured TCP/UDP translation separately.

The guest has no SSH, Tailscale, fleet key, SOPS age key, or host management services. Its only host filesystem windows are:

| Guest path | Host source | Access |
|---|---|---|
| `/var/lib/slskd` | block-backed `/mnt/virtio/slskd` compatibility bind | read/write |
| `/mnt/virtio/music/slskd` | block-backed Cratedigger handoff/download compatibility bind | read/write |
| `/mnt/virtio/Music/Beets` | curated library share | read-only |
| `/run/host-secrets/slskd` | slskd's own environment secret | read-only |
| `/nix/.ro-store` | host Nix store | read-only |

UID `988` and GID `968` are fixed on both sides of virtiofs to preserve the live `slskd:music-import` ownership. Cratedigger remains in `music-import` and sees the same host download path, so event-stamped completed-file locations do not change.

The native service's state was originally on doc2's disposable root disk at
`/var/lib/slskd`, then moved to `/mnt/virtio/slskd` for the microVM cutover.
Issue #51 moves that state again onto the dedicated block disk while retaining
`/mnt/virtio/slskd` as a compatibility bind, so the guest sees no app-directory
change.

The writable state and download paths no longer come from doc2's outer
virtiofs mount. A dedicated 300 GiB ext4 disk is mounted at
`/srv/slskd-storage`; its `state/` and `downloads/` directories are bind-mounted
over the legacy paths. The guest and Cratedigger therefore retain identical
event-stamped paths while the inner virtiofsd sees an ext4 backing filesystem,
not FUSE re-exported through FUSE.

The wrapper keeps `--inode-file-handles=prefer` for block-backed state/downloads,
the local ext4 Nix store, and the local ramfs secret. It rewrites only the
still-nested read-only library to `--inode-file-handles=never` and strips
unsupported ACL/xattr flags there. This distinction is load-bearing: globally
forcing `never` pinned
`O_PATH` descriptors into the outer FUSE mount and caused issue #51's sticky
ENOENT/ESTALE failures.

The host ext4 mount and both writable guest virtiofs mounts are independently
`nodev,nosuid,noexec`; host mount flags do not propagate through virtiofs. The
guest's Nix store, curated library, and secret shares are explicitly read-only.

## Dedicated block storage

prom provisions `nvmeprom/vm-114-slskd-storage` as a sparse 300 GiB zvol with
64K `volblocksize`, attached to VM 114 as `scsi0` with `cache=none`, discard, a
dedicated iothread, SSD semantics, and Proxmox backup enabled. doc2 formats it
as ext4 with fixed UUID `8b2fb269-84d2-4480-8fea-34bcf1d59b42` and mounts it:

```text
prom 64K sparse zvol
  -> VM 114 virtio-scsi-single scsi0
    -> doc2 ext4 /srv/slskd-storage (nodev,nosuid,noexec,noatime)
      -> state     bind-mounted at /mnt/virtio/slskd
      -> downloads bind-mounted at /mnt/virtio/music/slskd
        -> one virtiofs layer into the slskd microVM
```

The base and bind mounts are `nofail` so an absent data disk does not prevent
doc2 from booting for recovery. `microvm-virtiofsd@slskd` and every Cratedigger
unit that binds the handoff tree explicitly require the
block-backed bind mounts, so the pipeline fails closed rather than writing into
the hidden legacy directories on the outer virtiofs mount. The old source trees
stay intact and hidden below the compatibility bind mounts for the rollback
window.

The bridge requires systemd-networkd on a host whose PostgreSQL nspawn
containers otherwise use NixOS' container-owned veth setup. The stock
`80-container-ve.network` claims every `ve-*` link when networkd is enabled,
replaces the containers' fixed `10.20.0.0/24` host routes with generated
private subnets, and takes every database-backed service offline while the
containers themselves still look active. `10-nspawn-veth-unmanaged.network`
must sort before that stock rule and mark `ve-*` unmanaged. After first
deploying this protection over already-misconfigured links, restart the nspawn
containers once so their units recreate the fixed host-side routes; subsequent
container starts remain owned exclusively by the container setup.

## Host prerequisites

Nested virtualization is required. Proxmox has nested AMD-V enabled globally,
but VMID 114 previously used `x86-64-v3`, which hid SVM. `cpu=host` alone also
keeps SVM hidden on this Proxmox version; the VM-specific `+nested-virt` flag is
required. The cutover also adds the VLAN-tagged third NIC:

```bash
ssh root@prom 'qm set 114 --cpu host,flags=+nested-virt --net2 virtio,bridge=vmbr0,firewall=1,tag=21'
```

A full Proxmox stop/start is required for the CPU model; an in-guest reboot keeps
the existing QEMU process and does not expose SVM. After power-cycling, doc2
must show `svm` in `/proc/cpuinfo`, `/dev/kvm`, and `ens20`; the NixOS config
loads `kvm-amd`.

The existing `ens19 = 192.168.1.36` remains. It is no longer a slskd boundary, but Cratedigger's yt-dlp rescue worker still binds to it for source-policy-routed VPN egress. Do not remove its table-100 route while YouTube rescue is enabled.

Before booting the guest, create a UniFi vlan-only network `SLSKD_DMZ` with
VLAN ID 21. Trunk profiles use `tagged_vlan_mgmt=auto`, so no per-port change
is required. On pfSense create `igc1.21`, assign it as `SLSKD_DMZ`, and give it
`192.168.21.1/24` with no DHCP server.

## Issue #51 block-storage cutover

The live precopy may run while services are active, but the final copy must
quiesce every writer. SQLite WALs, partial downloads, and importer moves must
all converge before mounting over the legacy paths:

```bash
# The new filesystem must already be formatted and mounted. Never precopy into
# an unmounted /srv directory on doc2's root disk.
ssh doc2 'test "$(sudo blkid -s UUID -o value /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0)" = 8b2fb269-84d2-4480-8fea-34bcf1d59b42'
ssh doc2 'test "$(findmnt -rn -o UUID -T /srv/slskd-storage)" = 8b2fb269-84d2-4480-8fea-34bcf1d59b42'
ssh doc2 'sudo install -d -m0755 -o slskd -g music-import /srv/slskd-storage/state && sudo install -d -m0770 -o slskd -g music-import /srv/slskd-storage/downloads'

# Precopy while live.
ssh doc2 'sudo rsync -aHAXS --numeric-ids /mnt/virtio/slskd/ /srv/slskd-storage/state/'
ssh doc2 'sudo rsync -aHAXS --numeric-ids /mnt/virtio/music/slskd/ /srv/slskd-storage/downloads/'

# Final cutover. Stop timers first so they cannot restart a writer.
ssh doc2 'sudo systemctl stop cratedigger-metadata-gate-watchdog.timer cratedigger-metadata-gate-watchdog.service cratedigger.timer'
ssh doc2 'sudo systemctl stop cratedigger.service cratedigger-web.service cratedigger-importer.service cratedigger-import-preview-worker.service cratedigger-youtube-ingest.service'
ssh doc2 'sudo systemctl stop microvm@slskd.service microvm-virtiofsd@slskd.service'
ssh doc2 '! pgrep -fa "slskd|cratedigger" | grep -vE "calib|pgrep"'

ssh doc2 'sudo rsync -aHAXS --delete --numeric-ids /mnt/virtio/slskd/ /srv/slskd-storage/state/'
ssh doc2 'sudo rsync -aHAXS --delete --numeric-ids /mnt/virtio/music/slskd/ /srv/slskd-storage/downloads/'
ssh doc2 'test -z "$(sudo rsync -aHAXSni --delete --numeric-ids /mnt/virtio/slskd/ /srv/slskd-storage/state/)"'
ssh doc2 'test -z "$(sudo rsync -aHAXSni --delete --numeric-ids /mnt/virtio/music/slskd/ /srv/slskd-storage/downloads/)"'

# Deploy the signed revision. Activation installs and mounts the ext4 filesystem
# and compatibility binds before services are explicitly restarted below.
fleet-deploy doc2

# Explicitly restore every unit stopped above; switch-to-configuration does not
# restart an unchanged unit that an operator deliberately stopped.
ssh doc2 'sudo systemctl start microvm@slskd.service'
ssh doc2 'curl -fsS http://192.168.21.2:5030/health'
ssh doc2 'sudo systemctl start cratedigger-web.service cratedigger-importer.service cratedigger-import-preview-worker.service cratedigger-youtube-ingest.service cratedigger.timer cratedigger-metadata-gate-watchdog.timer'
```

After deployment, verify every source with `findmnt -T`, inspect the active
virtiofsd command lines, check SQLite integrity, and observe real
completed-download/import traffic. Keep both hidden source trees untouched for
rollback.

## Production cutover evidence (2026-07-27)

- Signed implementation commit `439c440692c8ab7a50b32892e1adb1a6e9946674`
  was fast-forwarded to Forgejo `master`. doc2 subsequently deployed its signed
  review/documentation descendants; exact revision evidence is retained in
  issue #51 rather than embedding a self-staling repository tip here.
- The final writer-quiesced sync and no-change rsync check matched exactly:
  state had 8 files, 7 directories, and 2,298,200,969 bytes; downloads had
  3,897 files, 786 directories, and 111,400,371,495 bytes.
- `/srv/slskd-storage` is `/dev/sda` ext4 with UUID
  `8b2fb269-84d2-4480-8fea-34bcf1d59b42`. The state and download paths resolve
  to `/dev/sda[/state]` and `/dev/sda[/downloads]`, with
  `rw,nosuid,nodev,noexec,noatime,errors=remount-ro`.
- The active writable virtiofsd processes use `inode-file-handles=prefer` on
  those ext4-backed binds. The local ext4 store and ramfs secret also retain
  `prefer --readonly`; only the nested library uses `never --readonly`.
- slskd reported `Databases are up to date`, opened HTTP 5030 and Soulseek TCP
  50300, connected and logged in, and returned `Healthy`. Online SQLite
  `quick_check` returned `ok` for all five state databases.
- Cratedigger web/importer/preview workers are active; the main run connected
  PostgreSQL and Redis, completed startup reconciliation, queried slskd events,
  and submitted searches. Its local web root returned HTTP 200.
- The initial post-cutover window contained zero known
  ENOENT/ESTALE/ENOMEM move signatures. It contained no new completed move, so
  this is topology/health verification rather than the one-week normalized
  move-rate acceptance result.
- The 300 GiB zvol remains sparse, `backup=1`, `cache=none`, discard-enabled,
  and iothread-backed. Both hidden legacy trees remain untouched for rollback.

Keep issue #51 open through at least 2026-08-03. Do not remove the restart
workaround or legacy trees until one full week of normalized move-failure data
is clean.

## Original native-service to microVM cutover (historical)

The state databases are SQLite files with WALs. Stop both the producer and slskd before taking the backup; do not copy a live database by file glob.

```bash
# Preflight
# Stop the gate watchdog first: while metadata is healthy it deliberately
# restarts cratedigger.timer, which in turn wants native slskd.service.
ssh doc2 'sudo systemctl stop cratedigger-metadata-gate-watchdog.timer cratedigger-metadata-gate-watchdog.service'
ssh doc2 'sudo systemctl stop cratedigger.timer cratedigger.service slskd.service'
ssh doc2 '! pgrep -f "^/nix/store/.*/slskd .*--app-dir /var/lib/slskd" && ! pgrep -f "^/nix/store/.*/python .*cratedigger.py"'
ssh doc2 'sudo tar --xattrs --acls -C /var/lib -czf /var/lib/slskd-pre-microvm.tar.gz slskd'
ssh doc2 'sudo tar -tzf /var/lib/slskd-pre-microvm.tar.gz >/dev/null'
ssh doc2 'sudo test ! -e /mnt/virtio/slskd && sudo install -d -m0755 -o slskd -g music-import /mnt/virtio/slskd'
ssh doc2 'sudo rsync -aHAX --numeric-ids /var/lib/slskd/ /mnt/virtio/slskd/'
ssh doc2 'sudo rsync -aHAXnc --delete --numeric-ids /var/lib/slskd/ /mnt/virtio/slskd/' # must print nothing

# Expose nested KVM + the tagged DMZ vNIC, then fully power-cycle VMID 114.
ssh root@prom 'qm set 114 --cpu host,flags=+nested-virt --net2 virtio,bridge=vmbr0,firewall=1,tag=21'
ssh root@prom 'qm shutdown 114 --timeout 60 && qm start 114'

# The old generation starts native slskd after boot. Quiesce convergence and
# refresh the portable copy before switching to the guest generation.
ssh doc2 'sudo systemctl stop cratedigger-metadata-gate-watchdog.timer cratedigger-metadata-gate-watchdog.service'
ssh doc2 'sudo systemctl stop cratedigger.timer cratedigger.service slskd.service'
ssh doc2 'sudo rsync -aHAX --delete --numeric-ids /var/lib/slskd/ /mnt/virtio/slskd/'
ssh doc2 'test -z "$(sudo rsync -aHAXnc --delete --numeric-ids /var/lib/slskd/ /mnt/virtio/slskd/)"'

# Deploy the signed Forgejo revision from doc1.
fleet-deploy doc2

# microvm.nix does not restart an already booted guest on every switch.
ssh doc2 'sudo systemctl restart microvm@slskd.service'
```

Retarget pfSense only after the guest API is healthy from doc2 and its Internet egress is verified. Apply these as one firewall change:

- add LAN TCP pass `192.168.1.35 -> 192.168.21.2:5030`, followed by a LAN block to `192.168.21.0/24`;
- on SLSKD_DMZ add DoT/DoH blocks, DNS pass to `.21.1:53`, RFC1918 block, USA-preferred/Netherlands-fallback pass, then terminal block;
- add USA and Netherlands outbound-NAT mappings for `192.168.21.0/24`;
- update USA pass `192.168.1.36:50300 -> 192.168.21.2:50300`;
- update USA NAT `45727 -> 192.168.1.36:50300` to `45727 -> 192.168.21.2:50300`.

Remove `192.168.1.36` from the `MV_VPN_IPS` alias only if no other workload still needs it; yt-dlp currently does, so it stays.

## Verification

Use observed traffic and state, not configuration alone.

Host-side virtiofsd changes (the wrapper or exact generated instance drop-in)
are included in the parent `microvm@slskd` restart trigger, while the child
retains `restartIfChanged=true`. NixOS therefore submits and waits for both stop
jobs (guest before backend) before activation, then both start jobs (backend
before guest). `PartOf=` alone is not a sufficient activation barrier: its
indirectly queued backend stop is absent from switch-to-configuration's wait
set and can be cancelled when the parent start is submitted, leaving dead
virtiofs sockets behind an apparently active supervisor.

```bash
# Host/guest boundary and preserved state
ssh doc2 'test -c /dev/kvm && grep -qm1 svm /proc/cpuinfo'
ssh doc2 'systemctl is-active microvm@slskd.service microvm-virtiofsd@slskd.service'
ssh doc2 'sudo journalctl -u microvm@slskd -b --no-pager | tail -100'
ssh doc2 'readlink -f /var/lib/microvms/slskd/current; readlink -f /var/lib/microvms/slskd/booted'
ssh doc2 'curl -fsS http://192.168.21.2:5030/health'
ssh doc2 'grep -E "^(host_url|download_dir)" /var/lib/cratedigger/config.ini'

# The only admitted host-to-guest socket is the API. Verify the Soulseek TCP
# listener from the USA forward/logs, not by widening the LAN exception.
ssh doc2 'nc -zvw3 192.168.21.2 5030'
ssh doc2 'sudo journalctl -u microvm@slskd -b --no-pager | grep -E "slskd|50300|Connected"'

# Data plane: counters must advance during a fresh guest request.
ssh doc2 'ip -s link show br-slskd; ip -s link show ens20'
```

Then verify through pfSense/live clients:

- a fresh guest HTTPS request exits the USA AirVPN public IP;
- read-only pfSense states show the `.21.2` flow on the USA tunnel and its outbound NAT;
- a genuinely external TCP probe reaches USA `45727`;
- no Netherlands NAT/pass rule exists for `45727`;
- a real inbound peer connection translates to `.21.2:50300`;
- guest attempts to every RFC1918 destination fail except `.21.1:53`;
- doc2 `.35 -> .21.2:5030` succeeds, while another LAN source fails;
- a Cratedigger search/enqueue produces slskd API activity and an event-stamped completed path in the unchanged download tree.

For controlled failover tests, use fresh connections and packet/state evidence.
Marking a gateway `force_down` tests gateway-group selection but does **not** make
the WireGuard transport unavailable; a physically live tunnel may still carry
traffic. Test the terminal kill switch by taking both `tun_wg*` interfaces down
through the pfSense MCP command-prompt surface, killing only the guest and its
two VPN-NAT state keys, and restarting the guest so it makes fresh connection
attempts. The guest API must remain healthy while slskd reports disconnected,
with no WAN or tunnel egress states. Restore both interfaces and clear every
temporary `force_down` flag before declaring success. Never flush all firewall
states.

## Accepted result

Acceptance completed on 2026-07-19 and is recorded in Forgejo
[#38 comment 177](https://git.ablz.au/abl030/nixosconfig/issues/38#issuecomment-177).

- USA-preferred egress produced fresh `tun_wg2` states and public TCP 45727 was
  externally open.
- With USA forced down, fresh guest connections moved to Netherlands `tun_wg0`.
- With both WireGuard interfaces physically down, slskd stayed API-healthy but
  disconnected from Soulseek and produced no WAN/tunnel egress state. It
  reconnected automatically after both transports were restored.
- A full doc2 reboot preserved the signed fleet anchor, IP-less host bridge,
  nspawn database routes, nested virtiofs, Cratedigger integration, and exact
  slskd share inventory: 12,578 directories and 106,490 files.
- Post-boot state had both VPN gateways online, the USA forward open, no
  metadata-gate holds, and zero failed units.

## Block-storage rollback

The pre-cutover source trees remain underneath the two compatibility bind
mounts. During the rollback window, do not delete either old tree or detach the
new disk. To return to nested storage while preserving writes made after
cutover:

1. stop `cratedigger-metadata-gate-watchdog.timer`, its service, `cratedigger.timer`, every Cratedigger unit that binds the handoff tree, `microvm@slskd`, and `microvm-virtiofsd@slskd`, in that order, so no timer can restart a writer and no daemon retains a handle into either bind mount;
2. unmount the state/download bind mounts, exposing the old outer-virtiofs trees;
3. sync `state/` and `downloads/` from `/srv/slskd-storage` back to those exposed paths with `rsync -aHAXS --delete --numeric-ids`;
4. deploy the signed parent configuration, which removes the dedicated mounts and restores the global nested-share wrapper;
5. start the guest and Cratedigger, then verify API health, Soulseek login, event paths, and a real completed transfer;
6. retain the detached zvol until the rollback has soaked and a current backup is verified.

Never sync into a hidden mountpoint: verify `findmnt -T` identifies the expected
source before either rollback copy.

## Native-service rollback

Rollback leaves the preserved files in place and returns the listener/forward to the native service:

1. retarget USA NAT and pass back to `192.168.1.36:50300`;
2. stop `microvm@slskd` and sync the guest's quiescent state back to the native path;
3. deploy the parent signed revision and start native `slskd.service` plus Cratedigger;
4. confirm `192.168.1.36:50300`, `localhost:5030`, Soulseek login, and Cratedigger API access;
5. only after recovery, remove VMID 114 `net2` or return its CPU type if desired.

```bash
ssh doc2 'sudo systemctl stop microvm@slskd.service'
ssh doc2 'sudo rsync -aHAX --delete --numeric-ids /mnt/virtio/slskd/ /var/lib/slskd/'
ssh doc2 'sudo systemctl start slskd.service cratedigger.service cratedigger.timer'
```

Do not delete the download tree during rollback. It is Cratedigger's live working set and contains state addressed by slskd completion events.
