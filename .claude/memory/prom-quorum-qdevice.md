---
name: prom-quorum-qdevice
description: prom is now a STANDALONE single-node Proxmox cluster (expected votes=1, no QDevice) as of 2026-07-02. It no longer depends on any external witness for quorum; qm/firewall writes just work. The old Caddy2.0 witness was removed.
metadata:
  type: reference
---

**As of 2026-07-02, prom is a self-quorate single-node cluster (`grevcluster`,
config_version 28): 1 node, `Expected votes: 1`, `Quorum: 1`, NO QDevice, `Flags:
Quorate`.** It no longer depends on any external witness. `qm clone` / `qm set` /
firewall writes just work; pmxcfs never goes read-only from a missing witness again.
If you EVER see prom non-quorate now, it's a NEW/different fault — do NOT go looking
for a witness to revive.

**History (what changed):** prom USED to be a single node + an external
corosync-QDevice witness (`corosync-qnetd`) on the **`Caddy2.0` KVM VM
(`192.168.1.6`) on tower** → expected votes = 2. During the edge-services migration
to **LXC 108 (`caddy-new`, same IP+MAC 192.168.1.6)**, the old caddy VM was stopped,
which killed the witness and wedged prom read-only. Reviving it was NOT an option: it
shares 192.168.1.6 with the live LXC 108, so booting it = duplicate IP/MAC on the LAN.

**The reusable recipe ("qdevice host is dead, regain quorum WITHOUT it"):** `pvecm
expected 1` does NOT work while a qdevice is configured (corosync ignores the
override — it returns exit 0 but nothing changes), and `pvecm qdevice remove` needs
quorum to write corosync.conf → deadlock. Break it by editing corosync.conf in
**local mode**:
```
systemctl stop pve-cluster corosync
systemctl stop corosync-qdevice; systemctl disable corosync-qdevice
pmxcfs -l                              # /etc/pve writable WITHOUT quorum
# edit /etc/pve/corosync.conf: delete the quorum{device{...}} stanza (keep
# provider: corosync_votequorum), delete the phantom `epi` node, bump config_version
cp /etc/pve/corosync.conf /etc/corosync/corosync.conf   # keep both copies identical
killall pmxcfs
systemctl start corosync; systemctl start pve-cluster
pvecm status   # -> Quorate: Yes, Expected 1, Flags: Quorate (no Qdevice)
```
Pre-change backups left on prom: `/root/corosync.conf.*.pre-qdevice-removal`.

**Consequences:** the old `Caddy2.0` VM on tower is now dead weight (safe to delete
once the LXC-108 migration is confirmed). The phantom `epi` (nodeid 1, 192.168.1.5)
nodelist entry was removed in the same edit. No HA resources exist, so the CRM
watchdog stays on standby and a quorum wobble won't fence prom. Full writeup:
`docs/wiki/infrastructure/prom-hypervisor.md` → *Cluster / quorum*. Related:
[[tower-unraid-fleet-ssh]], [[gaming-golden-image-v3]].
