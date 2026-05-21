---
name: reference-tower-unraid
description: tower (192.168.1.2) is an Unraid host outside the NixOS fleet — NAS + some VMs + docker stacks. SSH is gated.
metadata:
  type: reference
---

`tower` at `192.168.1.2` runs Unraid (NAS + VMs + docker stacks). It is **not** in the NixOS flake — no host entry in `hosts.nix`, no `nixos-rebuild` story.

Compute / VM split for the homelab:

- **prom** (192.168.1.12) — Proxmox host; runs most of the NixOS fleet VMs (doc1/proxmox-vm, doc2, igpu, dev, sandbox).
- **tower** (192.168.1.2) — Unraid host; NAS + a few VMs + docker stacks the user manages by hand.

**SSH access.** `ssh root@tower` and `ssh root@192.168.1.2` work but are **gated** — ask the user to unlock first before attempting. Do not assume access.
