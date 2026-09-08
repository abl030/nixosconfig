# imagegen — local text-to-image on CPU

**Last updated:** 2026-09-08
**Status:** working
**Owner:** `hosts/imagegen/configuration-lxc.nix`
**Host:** CT 110 on prom (unprivileged NixOS LXC), `192.168.1.37`

Local, fully offline image generation. No API, no account, no upload. Built to be
**switched on when wanted and cost nothing the rest of the time**.

## Why an LXC, and why not doc1

The instinct is to put this on the host with the most RAM. That is the wrong axis.

RAM is not the constraint — every model worth running fits in well under 25 GiB once
quantized. Compute is. And the deciding factor turned out to be *where the memory is
charged*, not how much exists:

| | KVM VM | Unprivileged LXC |
|---|---|---|
| Memory | **pinned reservation** — Proxmox backs virtiofs-enabled VMs with `memory-backend-memfd`, so doc1 + doc2 hold ~64 GiB resident between them and it shows up as `Shmem` | **cgroup ceiling** — `memory.max` caps it, `memory.current` is what it actually costs |
| Stopped | still holds nothing, but the allocation shape is fixed | returns everything instantly |
| AVX-512 | passed through (doc1 has it too) | native, unmasked |

Measured on the first real run: `memory.max` = 25.8 GB, `memory.current` = **8.0 GB**,
and prom's `available` was unchanged at 24 GB with the container pegging 23 cores. ZFS
ARC yielded 5.8 → 4.0 GB under the pressure, as it should.

The other reason not to use doc1: it is the bastion — Forgejo writer, binary cache,
control plane. Saturating 24 threads there for 40 minutes is antisocial.

**AVX-512 is not the differentiator.** doc1's vCPU already exposes the full Zen 5 set
(`avx512_bf16`, `avx512_vnni`). The LXC's wins are the elastic ceiling and staying off
the bastion.

## Off by default — two independent switches

Neither costs anything at rest. Both must be on to reach the WebUI.

```bash
# 1. the container itself (created --onboot 0)
ssh root@192.168.1.12 'pct start 110'      # ... and `pct stop 110` when done

# 2. ComfyUI inside it (systemd unit is wanted by no target)
ssh abl030@192.168.1.37 'sudo systemctl start comfyui'
```

`sd-cli` needs only step 1 — booting the container for a batch run deliberately does not
spin up a torch server.

## Not public, on purpose

No tailscale, no reverse proxy, no ACME, no Cloudflare record. ComfyUI **has no
authentication and executes arbitrary node graphs** — it is a remote-code-execution
surface by design. The host firewall (`allowedTCPPorts = [22 8188]`) on the LAN is the
only gate. Do not put it behind the edge proxy without an auth layer in front.

## The two halves

Both from the pinned nixpkgs, both cached — no local builds.

| | Package | Use it for |
|---|---|---|
| CLI | `stable-diffusion-cpp` → `sd-cli`, `sd-server` | Long batch runs. ggml + GGUF k-quants: far faster and leaner than torch on CPU. |
| WebUI | `services.comfyui` (upstream module) on `:8188` | Interactive work, building workflows. Runs `--cpu`, so PyTorch fp32 — slower and hungrier than sd-cli. |

Design the workflow in ComfyUI; run the overnight job with `sd-cli`.

`sd-server` is a third option worth knowing about — sd.cpp's own lightweight HTTP server,
much cheaper than ComfyUI if all you want is a queue with an API.

## Storage

`/var/lib/imagegen` is a Proxmox bind-mount of the ZFS dataset `nvmeprom/imagegen`
(`mp0 … backup=0`). Weights are re-downloadable, so they are deliberately excluded from
PBS. 1.6 TB free.

- `models/` — GGUF weights, owned by `abl030`
- `out/` — generated images
- `comfyui/` — ComfyUI state (`dataDir`), owned by the `comfyui` system user

The dataset root is chowned `100000:100000` — CT root under the unprivileged idmap.

## Running it

Z-Image Turbo, the current recommendation — 6B params, 8 steps, Apache-2.0-ish
(confirm on the model card). It is the pick *because* of the step count: 8 steps instead
of 20–50 means roughly 5x less compute for output that trades blows with FLUX.1-dev.

```bash
ssh abl030@192.168.1.37
cd /var/lib/imagegen && M=models
sd-cli --diffusion-model $M/z_image_turbo-Q8_0.gguf \
       --vae $M/ae.safetensors \
       --llm $M/qwen3-4b-Q4_K_M.gguf \
       --cfg-scale 1 --steps 8 -W 1024 -H 1024 -t 24 \
       -p "your prompt" -o out/result.png
```

`--cfg-scale 1` is required for a turbo/distilled model. `-t 24` matches the CT's cores.

Weights came from `leejet/Z-Image-Turbo-GGUF` (diffusion), `Comfy-Org/z_image_turbo`
(VAE — use this rather than `black-forest-labs/FLUX.1-schnell`, which is gated), and
`unsloth/Qwen3-4B-Instruct-2507-GGUF` (text encoder). Note Z-Image takes a **Qwen3-4B**
encoder via `--llm`, not qwen2vl — that is Qwen-Image's encoder.

## Measured performance

Z-Image Turbo, 24 cores of prom's 9950X, `--diffusion-fa`, seed 42, same prompt.
Measured 2026-09-08 on an otherwise-quiet box.

| Config | Wall | Per step | VAE decode | Peak RAM |
|---|---|---|---|---|
| Q4_K, 512x512, 4 steps | 283s | 58.9 s/it | 43.8s | |
| **Q8_0, 512x512, 4 steps** | **187s** | **35.1 s/it** | 43.6s | |
| Q4_K, 512x512, 4 steps, 12 threads | 335s | 70.1 s/it | 53.1s | |
| **Q8_0, 1024x1024, 8 steps** | **1818s (30.3 min)** | 205.2 s/it | 184.2s | 17.9 GB |

Two results worth internalising, both counterintuitive:

**Q8_0 is 34% FASTER than Q4_K** — the opposite of the usual GPU advice. On CPU we are
compute-bound, not memory-bound, and ggml's Q8_0 dequant path is far simpler SIMD than
Q4_K's unpacking. Use the heaviest quant that fits in RAM, not the smallest.

**Thread scaling is poor**: 24 threads beat 12 by only 15%, so it is memory-bandwidth
bound. **Two concurrent jobs at 12 threads beat one at 24** for batch throughput
(~21 vs ~13 images/hour), which is why `imagegen-batch` defaults to `PARALLEL=2`,
`THREADS=12`.

### Editing — the primary use case

**Qwen-Image-Edit-2509** (20B, Q4_K_S) + the **Lightning 4-step LoRA**, reference image
passed with `-r`:

| Config | Wall | Per step | Peak RAM |
|---|---|---|---|
| 512x512, 4 steps, Lightning | **1038s (17.3 min)** | 225.8 s/it | **23.05 GB** |

Verified good output, not noise: "replace the wooden table with a marble kitchen counter"
preserved the apple, its lighting and its angle, and changed only the surface.

Two things this pins down:

**The Lightning LoRA is not optional.** Stock Qwen-Image-Edit wants 20–40 steps, which at
226 s/step is 75 minutes to 2.5 hours *per image*. Distilled to 4 steps it is 17 minutes.
`--cfg-scale 1` goes with it — the distillation expects no classifier-free guidance.

**23.05 GB peak against a 24 GiB ceiling is the real memory constraint of this host**, and
it is why the [exclusivity rule](#exclusivity-with-imagegen-gpu--and-the-oom-that-taught-us)
exists. It fit with 11% to spare and `memory.events` reported `oom_kill 0`. Editing at
1024x1024 (4x the latent tokens) will **not** fit in 24 GiB — raise the ceiling first, with
the GPU VM stopped, or edit at 512.

### Versus the GPU

The GTX 1080 sibling ([`imagegen-gpu.md`](./imagegen-gpu.md)) is 12–30x faster at
generation, but 8 GB of VRAM cannot hold the 20B editor at all. The split that matters:

| Task | CPU (CT 110) | GPU (VM 123) |
|---|---|---|
| Generate 1024x1024 | 30.3 min | **79.5s** |
| Edit 512x512 | **17.3 min**, Qwen-Image-Edit 2509 Q4_K_S — the best open editor | 2.1 min, but only FLUX.1-Kontext **Q3_K_M**, the weakest of the three at an aggressive quant |
| Edit 1024x1024 | needs >24 GiB | 9.9 min, same quality caveat |

So: **generate on the GPU, edit on the CPU when the result matters.** The only thing that
gets both is a 12–16 GB card — every GPU failure was an allocation failure, never a speed
one.

## Exclusivity with imagegen-gpu — and the OOM that taught us

**CT 110 and VM 123 (`imagegen-gpu`) never run at the same time.** A Proxmox
`pre-start` hookscript wired to both (`local:snippets/imagegen-exclusive.sh`) stops the
other one automatically, so it is enforced rather than remembered.

This is not a preference; it is the fix for a real incident.

**2026-09-08:** both ran at once. The container peaked at **22.9 GB** against its 24 GB
ceiling while the GPU VM held 12 GB. prom's **global** OOM killer fired and killed
**doc1's kvm process**, rebooting the bastion.

The instructive part is *why the cgroup limit did not save us*:

- CT 110 `memory.events` showed `oom_kill 0` — the container **never hit its own limit**
- the kernel logged `constraint=CONSTRAINT_NONE ... global_oom` — the **host** ran out first
- so the global killer picked the largest RSS process, which on prom is always doc1 or
  doc2 (they pin ~64 GB between them via `memory-backend-memfd`), never the offender

**A cgroup ceiling only protects the host when it is set below the host's real headroom.**
Setting `memory.max` equal to what `free` reports as available leaves nothing for the
host and converts a would-be container OOM into a host OOM that kills something else.

### Raising the ceiling

24 GiB is sized to fit *with the GPU VM stopped*. prom has 123 GB and **no swap**. Before
raising either guest, check `free -g` on prom **and** subtract the other's allocation:

```bash
ssh root@192.168.1.12 'pct set 110 -memory 32768'   # takes effect on next CT start
```

## The GTX 1080

Built as **VM 123 `imagegen-gpu`** — see [`imagegen-gpu.md`](./imagegen-gpu.md). A VM
rather than a container because the card is `vfio-pci`-bound for the gaming VMs, and
Proxmox's refusal to let two VMs claim one PCI device *is* the interlock against them.

Pascal has no bf16 and 1:64 fp16 with only 8 GB VRAM, so the split is by model size: the
GPU takes what fits in 8 GB (Z-Image Turbo, SDXL, FLUX.1-Kontext at Q4), the CPU takes the
20B models that do not. Note `stable-diffusion-cpp-cuda` is not in the binary cache, so
that host needs a local CUDA build.

## Gotchas hit building this

- **Zero-secret hosts did not evaluate.** See the "host that consumes NO secrets" section
  of [`nixos-proxmox-lxc-guide.md`](../infrastructure/nixos-proxmox-lxc-guide.md). This
  host was the first with no sops secrets at all and tripped a latent fleet-wide bug.
- **`stable-diffusion-cpp` installs `sd-cli`/`sd-server`, not `sd`.** Older docs say `sd`.
- **`/var/lib/imagegen` root is CT-root-owned**, so `abl030` can only write `models/` and
  `out/`. Put scratch scripts in `~`.

## When to revisit

- If a smaller/faster model lands that beats Z-Image Turbo per unit of compute, swapping
  is just a new GGUF in `models/`.
- If the CPU numbers below prove too slow to live with, that is the trigger for the GPU
  VM, not before — build it against measured need.
