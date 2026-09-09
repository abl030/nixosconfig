---
name: imagegen-exclusive-cpu-gpu
description: prom's GTX 1080 has one owner at a time (imagegen-gpu VM 123 vs the gaming VMs), and a cgroup memory cap only protects the host when set below real headroom
metadata:
  type: project
---

**Current state (2026-09-09):** image generation lives ONLY on **VM 123
`imagegen-gpu`** (GTX 1080, ComfyUI at https://imagegen.ablz.au, normally on,
`onboot 1`). The CPU container CT 110 was **retired and destroyed** — a
20–30 minute all-cores job made the whole hypervisor sluggish, and the user
chose GPU speed over the 20B editor's quality.

**GPU ownership:** the 1080 is passed through, so exactly one VM can hold it.
A prom hookscript (`local:snippets/imagegen-exclusive.sh`, wired to gaming VMs
117/120/121) shuts 123 down before a gaming VM starts. Start 123 again after
gaming. Do not add a second GPU consumer without extending that script.

**The lesson that outlives the container.** On 2026-09-08 CT 110 (24 GB cgroup
cap) and VM 123 (12 GB) ran at once on prom (123 GB, **no swap**, doc1+doc2 pin
~64 GB via memory-backend-memfd). The container peaked at 22.9 GB, prom's
*global* OOM killer fired and killed doc1's kvm process — the bastion rebooted.
The container never hit its own limit (`memory.events` showed `oom_kill 0`);
the host ran out first.

**Why:** a cgroup ceiling only protects the host when it is set *below* the
host's real headroom. Sizing `memory.max` to whatever `free` reports as
available leaves nothing for the host, and the global killer picks the largest
RSS process — on prom always doc1 or doc2, never the offender.

**How to apply:** before giving any guest on prom more memory, check `free -g`
*and* subtract every other guest's allocation. Prefer a hookscript interlock
over a rule anyone has to remember. See `docs/wiki/services/imagegen-gpu.md`.
