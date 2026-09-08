# imagegen-gpu — GPU image generation on the GTX 1080

**Last updated:** 2026-09-08
**Status:** working, off by default
**Owner:** `hosts/imagegen-gpu/configuration.nix`
**Host:** `imagegen-gpu` — VM 123 on prom, `192.168.1.45`, `onboot 0`
**Sibling:** `imagegen` (CT 110, CPU — `hosts/imagegen/configuration-lxc.nix`) — the baseline this page compares against

## What this is

Phase 2 of local image generation. Phase 1 (`imagegen`, CT 110) runs
stable-diffusion.cpp on prom's 9950X. This host runs *the same binary* against
the GTX 1080 that normally belongs to the `apollo-*` gaming VMs, so the two
numbers are directly comparable: same model, same prompt, same seed, same
`--cfg-scale`.

The question it was built to answer was not "is a GPU faster" (obviously) but
**"can an 8 GB Pascal card do the thing the user actually wants, which is
editing existing photos?"**. Short answer: **partly — see the verdict.**

## Where it lives

- **VM:** 123 on prom, `q35` + OVMF, 8 cores, **12 GiB RAM**, 200 GiB on `nvmeprom`
- **GPU:** `hostpci0: 0000:01:00,pcie=1` — the whole IOMMU group 13 (GP104 + its HDMI audio function)
- **Models:** `/var/lib/imagegen/models` on the root filesystem (re-downloadable; not backed up)
- **Network:** LAN-only, `192.168.1.45`, sshd the only listening service. No tailscale, no reverse proxy, no web UI.

### Mutual exclusion with the gaming VMs is free

This is the reason it is a VM and not an LXC. The 1080 is bound to `vfio-pci`
on prom for passthrough, so a container cannot have it — but more usefully,
**Proxmox refuses to start a second guest that claims the same PCI device**. So
`imagegen-gpu` can never steal the GPU out from under a running `apollo-*`
gaming VM, and vice versa, with no coordination logic to write or maintain.

A *separate* mutual exclusion exists between VM 123 and CT 110 via the
`local:snippets/imagegen-exclusive.sh` pre-start hookscript, for a different
reason: memory. prom has 123 GB and **no swap**, and on 2026-09-08 running both
at once drove the global OOM killer into doc1's `kvm` process and rebooted the
bastion. Starting either guest now stops the other. That is correct behaviour,
not a fault.

## The two things that make this build work

Both are load-bearing and neither is obvious.

### 1. `cudaCapabilities = ["6.1"]`

nixpkgs' default CUDA capability set on this pin is
`["7.5" "8.0" "8.6" "8.9" "9.0" "10.0" "10.3" "12.0" "12.1"]` — Turing and
newer. A stock `stable-diffusion-cpp-cuda` therefore emits **no `sm_61` code at
all**, and PTX is only forward-compatible, so the binary loads on a 1080 and
then dies at the first kernel launch. Pinning `6.1` in `nixpkgs.config` makes
cmake receive `CMAKE_CUDA_ARCHITECTURES=61`
(`-gencode arch=compute_61,code=sm_61`).

It also makes the build much cheaper — one architecture instead of nine.

nixpkgs' default `cudaPackages` here is **12.9**, which still supports `sm_61`.
**CUDA 13 dropped Pascal**, so do not move this host to `cudaPackages_13`.

### 2. `nvidiaPackages.legacy_580`

NVIDIA's 580 branch is the **last** one supporting Maxwell/Pascal/Volta. On this
pin `latest`, `production`, `beta` and `new_feature` are all 595–610, which have
dropped Pascal. nixpkgs already classifies 580 as a legacy branch, so take it by
name rather than by version number.

The repo's existing `homelab.gpu.nvidia` module is deliberately **not** used: it
is written for the workstations (`hardware.opengl`, `nvidiaSettings`,
`modesetting`, power management), all of which exist to drive a monitor. This
host wants the kernel module, `libcuda` and `nvidia-smi` and nothing else.
`services.xserver.videoDrivers = ["nvidia"]` is still required — it is the
switch that arms nixpkgs' nvidia module — but no X server is enabled.

Verified in the guest: `NVIDIA GeForce GTX 1080, 8192 MiB, driver 580.178.04`.

## Benchmark results

Model: **Z-Image Turbo** (6B, 8-step distilled) via `sd-cli`, prompt
`"a red apple on a wooden table, studio lighting, sharp focus"`, `--seed 42`,
`--cfg-scale 1`, `--diffusion-fa`.

CPU column = `imagegen` CT 110, 24 threads of a 9950X.
GPU column = this host, GTX 1080. Times are `generate_image` (excludes model load).

| Run | CPU (CT 110) | GPU (1080) | Speed-up |
|---|---|---|---|
| Z-Image **Q4_K**, 512×512, 4 steps | **283.3 s** (58.94 s/it) | **14.6 s** (1.43 s/it) | **19.4×** wall, 41× per step |
| Z-Image **Q8_0**, 512×512, 4 steps | **187.2 s** (35.10 s/it) | **16.0 s** (1.41 s/it) | **11.7×** wall, 25× per step |
| Z-Image **Q4_K**, 1024×1024, 8 steps | ~40 min (est.) | **79.6 s** (7.31 s/it) | ~30× |
| Z-Image **Q8_0**, 1024×1024, 8 steps | not measured | **79.5 s** (7.15 s/it) | — |
| VAE decode, 512×512 | 43.8 s | 3.0 s (tiled) | 14× |
| VAE decode, 1024×1024 | — | 15.8 s (tiled) | — |

### The quantisation trade-off inverts on the GPU

On CPU, **Q8_0 was faster than Q4_K** (35.1 vs 58.9 s/it) — k-quant dequant
costs real CPU time. On the 1080 the two are within 1.5% of each other (1.41 vs
1.43 s/it): the dequant is hidden behind memory latency. So on GPU the quant
choice is **purely a VRAM decision, not a speed one** — and Q4_K's smaller
footprint (4909 MiB peak vs 7497 MiB) is what buys headroom.

### VRAM: what actually fits in 8 GiB

Peak VRAM measured by sampling `nvidia-smi` at 4 Hz for the whole run.

| Configuration | Peak VRAM | Result |
|---|---|---|
| Z-Image Q4_K, everything on GPU | 7907 MiB | **OOM** |
| Z-Image Q8_0, `te=cpu`, no tiling | 6609 MiB | **OOM** at VAE decode (wanted +1664 MiB) |
| Z-Image Q8_0, `te=cpu` + `--vae-tiling` | 7497 MiB | works |
| Z-Image Q4_K, `te=cpu` + `--vae-tiling` | **4909 MiB** | works, most headroom |
| Z-Image, 1024×1024, no tiling | 7219 MiB | **OOM** at VAE decode (wanted +6657 MiB) |

Two rules fall out of this, and they apply to every model on this card:

1. **Put the text encoder on the CPU** (`--backend te=cpu`). It runs once per
   image; its VRAM buys nothing. Z-Image's Qwen3-4B encoder alone is 3555 MiB of
   a 9988 MiB total — it is the difference between fitting and not.
2. **Always `--vae-tiling`.** The VAE decode is a *single huge allocation* —
   1664 MiB at 512×512, **6657 MiB at 1024×1024** — and it is what actually
   kills these runs, not the diffusion model. Tiling keeps the VAE on the GPU
   (3.0 s at 512, 15.8 s at 1024) instead of paying CPU decode time.

## Editing: the question that actually matters

The primary use case is **editing existing photos**, not text-to-image. Reference
image passed with `-r`; prompt
`"change the apple to a green pear, keep the wooden table and the studio lighting"`.

| Model | Size | Config | Result |
|---|---|---|---|
| **FLUX.1-Kontext-dev Q4_K_M** | 6.93 GiB | `te=cpu` + tiling, 1024², 8 steps | **OOM** — peak 7953/8192 MiB, still wanted +1505 MiB |
| **FLUX.1-Kontext-dev Q4_K_M** | 6.93 GiB | + `--max-vram 7 --stream-layers` | **OOM** — graph-cut does not rescue it |
| **FLUX.1-Kontext-dev Q3_K_M** | 5.37 GiB | `te=cpu` + tiling, 1024², 8 steps | **works** — 263.9 s (27.31 s/it), peak 7975 MiB |
| **FLUX.1-Kontext-dev Q3_K_M** | 5.37 GiB | `te=cpu` + tiling, 1024², **20 steps** | **works** — **592.1 s ≈ 9.9 min** (27.40 s/it), peak 7975 MiB |
| **FLUX.1-Kontext-dev Q3_K_M** | 5.37 GiB | `te=cpu` + tiling, **512²**, 20 steps | **works** — **125.3 s ≈ 2.1 min** (4.88 s/it), peak 6983 MiB |
| **Qwen-Image-Edit-2509 Q4_K_S** | 12.2 GiB | `--params-backend diffusion=disk --mmap` | **OOM** (VRAM) after 274 s |
| **Qwen-Image-Edit-2509 Q4_K_S** | 12.2 GiB | `--max-vram 7 --stream-layers` | **OOM** (VRAM) after 273 s |
| **Qwen-Image-Edit-2509 Q4_K_S** | 12.2 GiB | `--auto-fit` | **OOM** (VRAM), aborted |
| **Qwen-Image-Edit-2509 Q4_K_S** | 12.2 GiB | `--offload-to-cpu` | **killed by the OOM killer** (rc=137) |

### Qwen-Image-Edit-2509 is not usable here, and not only because of VRAM

Every offload strategy sd.cpp offers was tried and all four failed. The
`--offload-to-cpu` run is the interesting one: it died with **rc=137, the
kernel OOM killer**, because the model is 12.2 GiB and **this VM only has
12 GiB of RAM**. prom has no swap and its memory is the binding constraint on
the whole hypervisor, so "just give the VM more RAM" is not available — 12 GiB
is the cap. Qwen-Image-Edit at this quant cannot be resident in VRAM *or* in
system RAM.

A Q3_K_S (9.04 GiB) would at least fit in RAM and could be retried, but on the
Q4_K_S evidence the VRAM working set is the harder wall, not the weights.

### FLUX.1-Kontext-dev Q3_K_M is the one that works

Q4_K_M misses by roughly 1.5 GiB and no amount of streaming or graph-cutting
recovers it — the peak is already 7953 of 8192 MiB before the failing
allocation. **Q3_K_M is the largest Kontext quant that fits**, and it fits with
almost nothing to spare (7975 MiB peak, ~2% headroom).

## Verdict: is the GTX 1080 worth it for photo editing?

**Qualified yes, with a real caveat about quality.**

- **For text-to-image it is an unambiguous win.** 19–30× faster than the 24-core
  CPU path. A 512×512 draft drops from ~5 minutes to ~15 seconds, which changes
  it from a batch job into something interactive. If that were the only use
  case, the answer would be an easy yes.

- **For editing, the answer is "yes, but only with FLUX.1-Kontext-dev at
  Q3_K_M."** That is the *only* editor tested that fits. Concretely, a
  realistic 20-step edit costs **~10 minutes at 1024×1024** and **~2 minutes at
  512×512**. Two minutes is genuinely usable for iterating; ten minutes is a
  "start it and go and do something else" job — fine for a handful of photos,
  not for a session of trial and error at full resolution. And Q3_K_M is an
  aggressive quant of a 12B model run at the very edge of the card (7975 of
  8192 MiB, ~2% headroom), so expect quality below what the same model does at
  Q4+ on a larger card.

- **The best editor available today, Qwen-Image-Edit-2509, is out of reach** and
  cannot be brought into reach on this hardware. If editing quality is what
  matters most, the 1080 does not deliver it, and no software trick tested here
  changes that.

- **8 GB is the binding constraint, not compute.** Every failure in this whole
  exercise was an allocation failure; not one was "too slow". A 12 GB or 16 GB
  card would run Kontext at Q4_K_M or Q8_0 and would open up Qwen-Image-Edit.
  That — not a faster GPU — is the upgrade that would matter.

- **The sharing cost is real.** The GPU belongs to the gaming VMs; only one can
  run at a time, and the CT 110 hookscript means the CPU appliance stops too.
  For occasional editing that is fine. For anything continuous it is not.

**Recommendation:** keep the host for fast text-to-image drafting and for
Kontext-Q3_K_M edits, but do not retire the CPU path — and if photo editing
becomes the main workload, the answer is a card with more VRAM, not more of this
one.

## Operating it

```bash
# on prom — starting this stops CT 110 (hookscript), and needs the gaming VMs stopped
qm start 123
ssh abl030@192.168.1.45

# text-to-image (fastest working config)
M=/var/lib/imagegen/models
sd-cli --diffusion-model $M/z_image_turbo-Q4_K.gguf \
  --vae $M/ae.safetensors --llm $M/qwen3-4b-Q4_K_M.gguf \
  -p "..." --cfg-scale 1 --steps 4 -W 512 -H 512 --seed 42 \
  --diffusion-fa --vae-tiling --backend te=cpu -o out.png

# edit an existing image
sd-cli --diffusion-model $M/flux1-kontext-dev-Q3_K_M.gguf \
  --vae $M/ae.safetensors --clip_l $M/clip_l.safetensors --t5xxl $M/t5xxl-Q8_0.gguf \
  -r input.png -p "change X to Y, keep everything else" \
  --cfg-scale 1 --guidance 2.5 --steps 20 -W 1024 -H 1024 \
  --diffusion-fa --vae-tiling --backend te=cpu -o edited.png

qm shutdown 123   # NOT `qm stop` — see the gotchas
```

Raw results and per-run logs live in `/var/lib/imagegen/out/` on the host
(`gpu-bench-results.txt`).

## Provisioning gotchas (all of these bit during the build)

### `system.build.diskoImages` is broken fleet-wide on this nixpkgs pin

`docs/wiki/infrastructure/vm-provisioning.md` documents building
`config.system.build.diskoImages` on doc1 as the clean path. **It no longer
evaluates**, and not because of anything specific to this host — **doc2 fails
identically**:

```
error: vmTools: the `kernel` argument (kernel-modules) has no `target` attribute,
so the kernel image filename cannot be determined.
```

nixpkgs' `vmTools` split its `kernel` and `kernelModules` arguments; disko still
passes an aggregated module tree as `kernel`. Until disko catches up (or a local
override passes `kernelImage = "bzImage"`), that provisioning path is dead for
every host in this flake. **This host was installed offline instead**: loop-mount
a raw image on doc1, partition it to match disko's `disk-main-*` partlabels,
`nixos-install --root`, then `dd` onto the zvol. That is also why this host uses
OVMF + systemd-boot rather than doc2's seabios + GRUB — installing systemd-boot
offline is a file copy into the ESP, whereas GRUB wants a real block device to
embed `core.img` into.

### `boot.growPartition` grows the partition but not the filesystem

The module only runs `growpart`. Growing the ext4 inside the grown partition is
a separate step that systemd performs only for mounts carrying
**`x-systemd.growfs`**. Without it the first boot came up with a 200 GiB
partition and a 16 GiB filesystem. Fixed by
`fileSystems."/".options = ["x-systemd.growfs"]`.

### A ping sweep is NOT proof that a LAN address is free

`192.168.1.38` was chosen from a ping sweep that showed it idle. It is a
**pfSense static DHCP mapping for the Galaxy A55 phone** (`s-a55` — the same
handset that holds a fleet SSH key); the phone was simply asleep during the
sweep. The resulting address conflict poisoned the ARP caches on both doc1 and
prom and silently black-holed traffic in both directions — `ping` worked (both
devices answered) while TCP did not. **Check pfSense's static mappings and lease
table, not just ICMP.** The LAN DHCP pool is `.100–.200`; fleet statics live
below `.100`. This host is now on `.45`.

### The NIC name depends on the machine type

Proxmox's virtio NIC is `ens18` on i440fx (doc1, doc2) but **`enp6s18` on q35**,
and adding `hostpci` PCIe root ports can shift the bus number again. This host
pins the name by MAC with a `systemd.network.links` `.link` file (honoured by
udev whether or not systemd-networkd is enabled) and configures `lan`.

### `qm stop` is a hard power-off

It left ext4 dirty and the next boot dropped into emergency mode on a failed
`systemd-fsck`, with no way in because root has no password. Use `qm shutdown`.
The serial console (`console=ttyS0,115200` in `kernelParams`, `qm terminal 123`
on prom) and `services.qemuGuest.enable` were both added specifically because
diagnosing that blind was miserable.

### prom's host firewall blocks ad-hoc ports

Staging ~52 GiB of weights by serving them over HTTP from prom does not work:
`pve-firewall` drops inbound on anything but the management ports. The path that
works with no new port and no new credential is **doc1 as a relay** — doc1 sees
prom's pool over virtiofs (`/mnt/virtio` == `/nvmeprom/containers`) and already
has SSH to the VM. That ran at ~470 MB/s.
