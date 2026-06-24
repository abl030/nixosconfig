---
name: feedback-skill-over-script-ops
description: For operational/infra automation, write a Claude Code SKILL (agent discovers live state) — not a brittle hardcoded script
metadata:
  type: feedback
---

When building the `gaming-vm` skill I first bundled a bash helper that hardcoded
VMIDs, the template id, the shared MAC, the GPU PCI address, the IP, and a VMID
band. The user cut it off: *"no, script is brittle and out of date tomorrow.
make a skill! you'll use smarts."*

**Why:** hardcoded fleet/hypervisor values (VMIDs, MACs, PCI addresses, IPs,
which VMs even exist) drift constantly, so a frozen script lies within a day. A
`SKILL.md` that tells the agent to **discover live state first** (`qm list`, find
the template / GPU occupants / a free VMID) and reconcile against reference
values stays correct as the world moves.

**How to apply:** write operational/infra skills as judgment-driven instructions
that LEAD with live discovery; present concrete values as "current as of <date>,
verify live," never as a rigid script. Reserve bundled scripts for genuinely
static, pure logic. Pattern to copy: `.claude/skills/gaming-vm/SKILL.md`.
Related: [[feedback-commit-pathspec-staged-wip]].
