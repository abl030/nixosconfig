# iGPU passthrough to the `igpu` VM

**Last updated:** 2026-04-15
**Status:** working (after Proxmox host reboot)
**Host:** `igpu` (VMID 109) on `prom` (AMD 9950X)
**Owner:** `hosts/igpu/configuration.nix` + `hosts.nix` (`igpu.proxmox.hostpci`)
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208)

## What's passed through

The AMD iGPU on the 9950X (Granite Ridge integrated Radeon Graphics) is passed through to the `igpu` VM so jellyfin/plex/tdarr can do hardware transcoding inside guest containers.

Inside the guest, the PCIe topology looks like:

```
00:01.0  VGA  bochs-drm              (QEMU's virtual VGA — the "console")
01:00.0  VGA  AMD Granite Ridge      (the real passed-through iGPU, amdgpu driver)
```

The expected `/dev/dri` layout when things are healthy:

```
/dev/dri/
├── card0       -> 00:01.0  bochs virtual VGA
├── card1       -> 01:00.0  AMD iGPU
├── renderD128  -> 01:00.0  AMD render node (VA-API / compute)
└── by-path/
    ├── pci-0000:00:01.0-card    -> ../card0
    ├── pci-0000:01:00.0-card    -> ../card1
    └── pci-0000:01:00.0-render  -> ../renderD128
```

If `card1` and `renderD128` are missing but `lspci -nnk` still shows `amdgpu` bound to `01:00.0`, the driver loaded but never finished DRM device creation. See [Failure mode](#failure-mode-driver-bound-no-dri-device) below.

## Why `rebootOnKernelUpdate = false` is load-bearing

`hosts/igpu/configuration.nix` explicitly sets:

```nix
homelab.update = {
  enable = true;
  rebootOnKernelUpdate = false;  # see docs/wiki/infrastructure/igpu-passthrough.md
  ...
};
```

The reason: the AMD iGPU is known to fail its PCIe function-level reset (FLR) when the guest reboots under the kernel-upgrade path. The symptom is the [Failure mode](#failure-mode-driver-bound-no-dri-device) below — `amdgpu` binds but DRM init silently fails. Only a **Proxmox host reboot** (which power-cycles the iGPU from the host's perspective) clears it.

Auto-rebooting the guest on kernel upgrades used to leave igpu stuck without transcoding roughly once a month. We've seen this three times:

- ~Jan 2026 — first occurrence, traced back to a kernel auto-reboot two nights prior.
- April 2026 (early in #208 work) — hit it again during the compose cleanup; `/dev/dri/renderD128` missing, only `card0-Virtual-1` present in `/sys/class/drm/`. Proxmox host reboot restored it.
- April 2026 (Phase 1 virtiofs work) — `qm shutdown 109` hung mid-shutdown after `qm set` added the two new virtiofs devices. Hard `qm stop` would have risked the FLR-stuck state. User aborted with a Proxmox host reboot, which both stopped the VM and reset the iGPU state cleanly. Lesson: never `qm stop` an iGPU-passthrough VM; if shutdown hangs, host-reboot is the recovery.

If the upstream amdgpu FLR handling improves or if we switch to a hardware reset mechanism, revisit this and consider re-enabling `rebootOnKernelUpdate`.

## Verification

Post-reboot, the cheap health check is:

```
$ ssh igp 'ls /dev/dri/by-path/'
pci-0000:00:01.0-card
pci-0000:01:00.0-card
pci-0000:01:00.0-render
```

All three links = healthy. Missing `01:00.0-card` / `01:00.0-render` = broken.

For an end-to-end test, the tdarr node logs will emit an encoder matrix on startup:

```
$ ssh igp 'journalctl -u podman-tdarr-node -n 200 | grep encoder-enabled'
encoder-enabled-working,libx264-true-true,libx265-true-true,
  h264_nvenc-...,hevc_vaapi-true-true,...
```

`hevc_vaapi-true-true` = VAAPI HEVC encode path is functional. That's the one plex and jellyfin also use.

## Failure mode: driver bound, no DRI device

Symptoms seen this session (pre-reboot):

- `lspci -nnk` shows `Kernel driver in use: amdgpu` on `01:00.0` ✓
- `/dev/dri/` contains only `card0` (bochs) — no `card1`, no `renderD128`
- `/sys/class/drm/` has `card0-Virtual-1` only; none of the expected `card1-{DP,HDMI,Writeback}-*` nodes
- `/dev/dri/by-path/` only has `pci-0000:00:01.0-card → ../card0`
- Tdarr-node's encoder test reports `hevc_vaapi-true-false` or all hw codecs `-false`

What doesn't fix it:
- Rebooting the guest VM alone — the iGPU stays in the same stuck state.
- Unbinding / rebinding `amdgpu` — driver says it's happy; DRM core still won't produce devices.
- Reloading `amdgpu` with different parameters — same story.

What does fix it: **reboot the Proxmox host**. Cold power cycle isn't necessary — a normal `systemctl reboot` on prom is enough to power-cycle the PCIe device from the host side.

## How the passthrough is configured

Guest-side VM config lives in `hosts.nix` under `igpu.proxmox` (cores, memory, disk, BIOS, etc.). The actual `hostpci` line that attaches `01:00.0` to the VM is part of the imported VM definition on Proxmox (`ignoreInit = true` in `hosts.nix` preserves the existing hostpci binding across OpenTofu runs — we don't re-render it).

Guest kernel params relevant to iGPU init (from `hosts/igpu/configuration.nix`):

```nix
boot.kernelPackages = pkgs.linuxPackages_latest;
boot.kernelParams = ["cgroup_disable=hugetlb"];

hardware = {
  graphics.enable = true;
  enableRedistributableFirmware = true;
  cpu.amd.updateMicrocode = true;
};
```

`amdgpu` is provided by `hardware.graphics.enable = true`. User `abl030` is in `video` and `render` groups (for rootless compose stacks — tdarr-node runs rootful so it doesn't need this).

## What uses the iGPU today

| Consumer | How it gets `/dev/dri` | Lives in |
|---|---|---|
| `tdarr-node` | `virtualisation.oci-containers.containers.tdarr-node.extraOptions = ["--device=/dev/dri:/dev/dri"]` | `modules/nixos/services/tdarr-node.nix` |
| `jellyfin` | compose stack, `devices: - /dev/dri:/dev/dri` (still rootless) | `stacks/jellyfinn/docker-compose.yml` |

Jellyfin is the last compose stack on igpu (the local **plex2** test instance was retired in `739dd48`; production Plex lives on tower/Unraid and isn't part of this story). Jellyfin's migration to native `services.jellyfin` is Phase 3 of `#208` — once that lands, `homelab.containers.enable` can be set to `false` on igpu and the rootful/rootless `storage.conf` race documented in [tdarr-node.md](../services/tdarr-node.md#shared-storageconf-race-between-rootful-and-rootless-podman) goes away.

The endgame on igpu is **jellyfin (native NixOS) running alongside the existing tower-Plex** — they're not exclusive. Both serve the same media library; jellyfin just adds a second front-end with native VAAPI on the iGPU. Tower-Plex stays the primary streaming target for clients that prefer it.

## When to revisit

- When jellyfin migrates off compose → add it to the consumer table above; its `/dev/dri` passthrough will move into the new service module (likely `services.jellyfin` with `serviceConfig.DeviceAllow = [ "/dev/dri/renderD128 rw" "/dev/dri/card1 rw" ]`).
- If the "driver bound, no DRI device" failure stops happening for a year → consider flipping `rebootOnKernelUpdate` back on and verifying.
- If we replace the iGPU with a discrete GPU or a different AMD chip → re-verify the FLR behaviour before trusting auto-reboot.

## Related

- `hosts/igpu/configuration.nix` — host config + the `rebootOnKernelUpdate = false` choice
- `hosts.nix` (igpu block) — VM spec, `hostpci` inheritance via `ignoreInit`, `virtiofs` mappings
- `modules/nixos/services/tdarr-node.nix` — current OCI consumer of `/dev/dri`
- `stacks/jellyfinn/docker-compose.yml` — last compose-era consumer pending migration
- [`media-filesystem.md`](media-filesystem.md) — virtiofs storage layout including the `qm shutdown` vs `qm stop` rule
