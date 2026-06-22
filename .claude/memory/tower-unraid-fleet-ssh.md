---
name: tower-unraid-fleet-ssh
description: tower (Unraid) is now a native-OpenSSH fleet SSH member; Tailscale SSH is OFF
metadata: 
  node_type: memory
  type: project
  originSessionId: 49161e20-a020-41eb-a8ff-cf287ff253c6
---

**2026-06-22:** tower (Unraid 7.3.0, 192.168.1.2 / 100.103.140.44) was moved off
Tailscale-SSH-only onto the **standard doc1-bastion fleet SSH model**. Reach it from doc1
with the fleet key like any sibling: `ssh root@tower` (or `root@192.168.1.2`). Pubkey-only
(no password, `PermitRootLogin prohibit-password`, `AllowUsers root`); only `fleetIdentity`
(`…QQS0K1qy`) is authorized. The Tailscale plugin's `--ssh` is **disabled** (`RunSSH:false`),
so the old "tower = Tailscale SSH" assumption and the CLAUDE.md "ssh root@tower … gated"
note are STALE.

The ACL root widening this session (commit `c6d75b84`, allowing root over Tailscale SSH) was
**reverted** (`27c90f67`) — doc1→tower now rides the existing `tag:server` mesh grant, no
ssh-block rule needed. The ssh-block is back to nonroot-only (still used by downloader2).

tower is NOT Nix-managed — the whole config lives on the Unraid **flash** and is the only
record. Full setup, persistence map, reboot recovery, and rollback:
`docs/wiki/infrastructure/tower-unraid-fleet-ssh.md`. See also [[tailscale-acl-state]].
