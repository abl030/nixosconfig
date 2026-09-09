# imagegen — CPU image generation (RETIRED)

**Last updated:** 2026-09-09
**Status:** retired and destroyed 2026-09-09 — CT 110, its `nvmeprom/imagegen` dataset and the LXC template are gone
**Successor:** [`imagegen-gpu.md`](./imagegen-gpu.md) — VM 123, ComfyUI at https://imagegen.ablz.au

## Why it was retired

It worked. A 512px edit with the 20B Qwen-Image-Edit 2509 completed in 17 minutes at
full quality, and a 1024px Z-Image render in 30. But every job pinned 24 of prom's 32
threads for that long, and prom is the hypervisor under doc1, doc2 and Home Assistant —
the whole house got sluggish while an image cooked. The user chose the GTX 1080's speed
(2–10 min, lower-quality editor) over the CPU's quality, and a single box over two.

## What is worth keeping from it

Measured 2026-09-08 on 24 threads of a 9950X, `stable-diffusion.cpp`, `--diffusion-fa`:

| Config | Wall | Per step | Peak RAM |
|---|---|---|---|
| Z-Image Turbo Q4_K, 512², 4 steps | 283s | 58.9 s/it | |
| **Z-Image Turbo Q8_0, 512², 4 steps** | **187s** | **35.1 s/it** | |
| Z-Image Turbo Q4_K, 512², 4 steps, 12 threads | 335s | 70.1 s/it | |
| Z-Image Turbo Q8_0, 1024², 8 steps | 1818s | 205 s/it | 17.9 GB |
| Qwen-Image-Edit-2509 Q4_K_S + Lightning 4-step, 512² edit | 1038s | 226 s/it | 23.05 GB |

Three things that generalise beyond this host:

1. **On CPU, Q8_0 was 34% *faster* than Q4_K** — the opposite of GPU advice. Compute-bound,
   and ggml's Q8_0 dequant is far simpler SIMD than Q4_K's unpacking. On the 1080 the two
   were within 1.5%.
2. **Thread scaling was poor** (24 threads bought 15% over 12): memory-bandwidth bound, so
   two concurrent 12-thread jobs beat one 24-thread job for throughput.
3. **A cgroup ceiling only protects the host when set below real headroom.** Running this
   container (24 GB cap) alongside the GPU VM (12 GB) exhausted prom — no swap, doc1+doc2
   pinning ~64 GB — and the *global* OOM killer took doc1. `memory.events` on the container
   showed `oom_kill 0`: it never hit its own limit. Details and the interlock that came out
   of it: [`imagegen-gpu.md`](./imagegen-gpu.md), memory `imagegen-exclusive-cpu-gpu`.

## Fleet-wide side effect that stays

This was the first host with **zero sops secrets**, which exposed that two shared modules
ordered activation scripts after sops-nix's `setupSecrets` unconditionally — a script sops
only defines when secrets exist. `homelab.secrets.hasSetupSecrets`
(`modules/nixos/common/secrets.nix`) is the fix and remains in place. See the "host that
consumes NO secrets" section of
[`nixos-proxmox-lxc-guide.md`](../infrastructure/nixos-proxmox-lxc-guide.md).

## The share is still in use

`/mnt/data/Life/Temp/imagegen/` on tower carried over unchanged for the user: photos to
edit go in `in/`, ComfyUI renders land in `comfyui/`. The CPU-era `queue.txt` runner and
its `queue-done/` archive were removed with the container.
