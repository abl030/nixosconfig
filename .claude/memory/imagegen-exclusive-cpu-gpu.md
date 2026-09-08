---
name: imagegen-exclusive-cpu-gpu
description: imagegen CPU LXC (CT 110) and imagegen-gpu VM (VM 123) on prom must never run at the same time
metadata:
  type: project
---

The two image-generation hosts on prom are **mutually exclusive — only one runs
at a time**. CT 110 (`imagegen`, CPU) and VM 123 (`imagegen-gpu`, GTX 1080) must
never be running simultaneously.

**Why:** prom has 123 GB and **no swap**, and doc1 + doc2 hold ~64 GB resident
(Proxmox backs virtiofs-enabled VMs with `memory-backend-memfd`, so their RAM is
pinned, not reclaimable). On 2026-09-08 both image hosts ran at once — the CPU
container peaked at 22.9 GB against a 24 GB ceiling while the GPU VM held 12 GB —
and prom's **global** OOM killer fired and killed doc1's kvm process, rebooting
the bastion. The container never hit its own cgroup limit (`memory.events`
showed `oom_kill 0`); the host ran out first.

The lesson generalises: **a cgroup ceiling only protects the host when it is set
below the host's real headroom.** Setting a container's `memory.max` equal to
what `free` reports as available leaves nothing for the host, and the global OOM
killer then picks the largest RSS process — which on prom is always doc1 or doc2,
never the offender.

**How to apply:** keep both off by default (`onboot 0`). Starting either one
stops the other — enforced by a Proxmox `pre-start` hookscript wired to both, so
it is automatic rather than a thing to remember. Before raising either one's
memory, check `free -g` on prom *and* subtract the other's allocation.
