# slskd microVM cage

**Built:** 2026-07-19 · **Status:** ready for cutover · **Tracking:** Forgejo [#38](https://git.ablz.au/abl030/nixosconfig/issues/38)

slskd parses Internet peer traffic and accepts the USA AirVPN `45727` forward. It therefore runs in a dedicated `microvm.nix` / cloud-hypervisor guest instead of doc2's host namespace. The configuration is `hosts/doc2/slskd-microvm.nix`.

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
| `/var/lib/slskd` | `/mnt/virtio/slskd` (migrated state) | read/write |
| `/mnt/virtio/music/slskd` | Cratedigger handoff/download tree | read/write |
| `/mnt/virtio/Music/Beets` | curated library share | read-only |
| `/run/host-secrets/slskd` | slskd's own environment secret | read-only |
| `/nix/.ro-store` | host Nix store | read-only |

UID `988` and GID `968` are fixed on both sides of virtiofs to preserve the live `slskd:music-import` ownership. Cratedigger remains in `music-import` and sees the same host download path, so event-stamped completed-file locations do not change.

The native service's state was on doc2's disposable root disk at
`/var/lib/slskd`. Cutover copies it to `/mnt/virtio/slskd`, matching the
portable containers dataset and backup inventory; the guest mounts that path
back at `/var/lib/slskd`, so slskd sees no app-directory change.

## Host prerequisites

Nested virtualization is required. Proxmox has nested AMD-V enabled globally, but VMID 114 previously used `x86-64-v3`, which hid SVM. The cutover changes it to `cpu=host` and adds the VLAN-tagged third NIC:

```bash
ssh root@prom 'qm set 114 --cpu host --net2 virtio,bridge=vmbr0,firewall=1,tag=21'
```

A reboot is required for the CPU model and NIC. After reboot, doc2 must show `svm` in `/proc/cpuinfo`, `/dev/kvm`, and `ens20`; the NixOS config loads `kvm-amd`.

The existing `ens19 = 192.168.1.36` remains. It is no longer a slskd boundary, but Cratedigger's yt-dlp rescue worker still binds to it for source-policy-routed VPN egress. Do not remove its table-100 route while YouTube rescue is enabled.

Before booting the guest, create a UniFi vlan-only network `SLSKD_DMZ` with
VLAN ID 21. Trunk profiles use `tagged_vlan_mgmt=auto`, so no per-port change
is required. On pfSense create `igc1.21`, assign it as `SLSKD_DMZ`, and give it
`192.168.21.1/24` with no DHCP server.

## Cutover

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

# Expose nested KVM + the tagged DMZ vNIC, then reboot doc2.
ssh root@prom 'qm set 114 --cpu host --net2 virtio,bridge=vmbr0,firewall=1,tag=21'
ssh doc2 'sudo reboot'

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

For controlled failover tests, use fresh connections and packet/counter evidence. USA down must move guest egress to Netherlands while losing inbound reachability. Both VPNs down must time out, with a simultaneous physical-WAN capture showing zero packets for the unique test destination. Never flush all firewall states.

## Rollback

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
