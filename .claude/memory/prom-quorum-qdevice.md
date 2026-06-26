---
name: prom-quorum-qdevice
description: prom Proxmox quorum depends on a corosync-QDevice witness running on the Caddy2.0 VM (192.168.1.6) on tower — if that VM is down, pmxcfs goes read-only and all qm writes fail
metadata:
  type: reference
---

**prom is a single-node Proxmox "cluster" (`grevcluster`) + an external
corosync-QDevice witness.** The witness (`corosync-qnetd`) runs on the **`Caddy2.0`
KVM VM (`192.168.1.6`)** on the **tower** Unraid host. Expected votes = 2 (prom 1 +
QDevice 1); quorum = 2.

**Failure mode:** if `Caddy2.0` is down/unreachable, prom drops to 1/2 votes →
**`Quorate: No, Activity blocked`** → pmxcfs (`/etc/pve`) goes **READ-ONLY**. Reads
(`qm list`/`config`) still work from cache, but every WRITE fails:
- `qm clone` / `qm set` → `cluster not ready - no quorum?`
- firewall edits (`/etc/pve/firewall/*.fw`) → `Permission denied` (and pmxcfs rejects
  `>>` append regardless — write whole files via `qm`/Python truncate-write).

**Fix:** revive the witness, do NOT band-aid with `pvecm expected 1`. Start `Caddy2.0`
on tower (the **`tower` subagent**: `virsh start "Caddy2.0"`), then confirm on prom:
`pvecm status` → `Quorate: Yes`, qdevice flag `A,V` (Alive+Voting, not `A,NV`).
Config: `/etc/corosync/corosync.conf` → `quorum.device.net.host: 192.168.1.6`.

Hit during the v2 golden-image build (2026-06-26; see [[gaming-golden-image-v3]]) —
`qm clone` failed until Caddy2.0 was started. Other nodelist entry `epi` (nodeid 1) is historical, not a live
voter. Related: [[tower-unraid-fleet-ssh]].