---
name: imagegen-exclusive-cpu-gpu
description: prom guest memory — a cgroup cap only protects the host when set below real headroom (lesson from the retired imagegen hosts)
metadata:
  type: project
---

**Current state (2026-10-16):** no image-generation host exists. CT 110 (CPU)
was destroyed 2026-09-09 and VM 123 `imagegen-gpu` was removed from the repo
2026-10-16 (never used; the GTX 1080 is too weak). The GTX 1080 now belongs to
the gaming VMs alone, and the `imagegen-exclusive.sh` hookscript is gone.

**The lesson that outlives both.** On 2026-09-08 CT 110 (24 GB cgroup cap) and
VM 123 (12 GB) ran at once on prom (123 GB, **no swap**, doc1+doc2 pin ~64 GB
via memory-backend-memfd). The container peaked at 22.9 GB, prom's *global* OOM
killer fired and killed doc1's kvm process — the bastion rebooted. The container
never hit its own limit (`memory.events` showed `oom_kill 0`); the host ran out
first.

**Why:** a cgroup ceiling only protects the host when it is set *below* the
host's real headroom. Sizing `memory.max` to whatever `free` reports as
available leaves nothing for the host, and the global killer picks the largest
RSS process — on prom always doc1 or doc2, never the offender.

**How to apply:** before giving any guest on prom more memory, check `free -g`
*and* subtract every other guest's allocation. Prefer a hookscript interlock
over a rule anyone has to remember. History: `docs/wiki/services/imagegen-gpu.md`.
