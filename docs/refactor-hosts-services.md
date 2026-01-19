# Refactor: Relocate hosts/services to modules/nixos

**Status**: IN PROGRESS (Phase 1 complete)
**Started**: 2026-01-19
**Reset**: 2026-01-19

## Problem

The `hosts/` directory mixes inventory (specific machines) with logic (service configurations). This breaks the "Inventory vs. Library" separation pattern.

## Goal

Move `hosts/services/*` into `modules/nixos/services/` as proper NixOS modules with `homelab.*` options.

## Current State Analysis

### Files to Relocate

| Source | Used By | Target Module |
|--------|---------|---------------|
| `hosts/services/mounts/nfs.nix` | epi, framework | `homelab.mounts.nfs` |
| `hosts/services/mounts/nfs_local.nix` | igpu, proxmox-vm | `homelab.mounts.nfsLocal` |
| `hosts/services/mounts/cifs.nix` | (unused) | `homelab.mounts.cifs` |
| `hosts/services/mounts/ext.nix` | proxmox-vm | `homelab.mounts.external` |
| `hosts/services/mounts/fuse.nix` | igpu, proxmox-vm | `homelab.mounts.fuse` |
| `hosts/services/nvidia/nvidia.nix` | (unused) | `homelab.gpu.nvidia` |
| `hosts/services/nvidia/intel.nix` | epi | `homelab.gpu.intel` |
| `hosts/services/display/gnome-remote-desktop.nix` | (unused) | (skip or homelab.display.gnomeRdp) |
| `hosts/services/display/sunshine.nix` | (unused - duplicate exists) | SKIP - already in modules |
| `hosts/services/system/remote_desktop_nosleep.nix` | epi, framework | `homelab.rdpInhibitor` |
| `hosts/services/virtualisation/cockpit.nix` | (unused) | `homelab.virtualisation.cockpit` |
| `hosts/services/virtualisation/virtman.nix` | (unused) | `homelab.virtualisation.libvirt` |
| `hosts/services/virtualisation/incus.nix` | (unused) | `homelab.virtualisation.incus` |

### Existing Module Pattern

From `modules/nixos/services/display/sunshine.nix`:
```nix
{config, lib, pkgs, ...}:
with lib; let
  cfg = config.homelab.sunshine;
in {
  options.homelab.sunshine = {
    enable = mkEnableOption "Enable Sunshine Game Stream Server";
  };
  config = mkIf cfg.enable { ... };
}
```

### Host Import Pattern (Current)

```nix
# hosts/epi/configuration.nix
imports = [
  ../services/mounts/nfs.nix      # Direct import
  ../services/nvidia/intel.nix    # Direct import
];
```

### Host Import Pattern (Target)

```nix
# hosts/epi/configuration.nix
{
  homelab.mounts.nfs.enable = true;
  homelab.gpu.intel.enable = true;
}
```

## Implementation Checklist

### Phase 1: Mounts (Active Use - 4 hosts affected)
- [ ] Create `modules/nixos/services/mounts/default.nix`
- [ ] Create `modules/nixos/services/mounts/nfs.nix` (homelab.mounts.nfs)
- [ ] Create `modules/nixos/services/mounts/nfs-local.nix` (homelab.mounts.nfsLocal)
- [ ] Create `modules/nixos/services/mounts/fuse.nix` (homelab.mounts.fuse)
- [ ] Create `modules/nixos/services/mounts/external.nix` (homelab.mounts.external)
- [ ] Register in `modules/nixos/services/default.nix`
- [ ] Update epi to use `homelab.mounts.nfs.enable = true`
- [ ] Update framework to use `homelab.mounts.nfs.enable = true`
- [ ] Update igpu to use new mounts modules
- [ ] Update proxmox-vm to use new mounts modules
- [ ] Run drift detection - should show MATCH for all 4 hosts
- [ ] Delete `hosts/services/mounts/`

### Phase 2: GPU Drivers (1 host affected)
- [ ] Create `modules/nixos/services/gpu/default.nix`
- [ ] Create `modules/nixos/services/gpu/intel.nix` (homelab.gpu.intel)
- [ ] Create `modules/nixos/services/gpu/nvidia.nix` (homelab.gpu.nvidia)
- [ ] Register in `modules/nixos/services/default.nix`
- [ ] Update epi to use `homelab.gpu.intel.enable = true`
- [ ] Run drift detection - should show MATCH for epi
- [ ] Delete `hosts/services/nvidia/`

### Phase 3: System Services (2 hosts affected)
- [ ] Create `modules/nixos/services/rdp-inhibitor.nix` (homelab.rdpInhibitor)
- [ ] Register in `modules/nixos/services/default.nix`
- [ ] Update epi to use `homelab.rdpInhibitor.enable = true`
- [ ] Update framework to use `homelab.rdpInhibitor.enable = true`
- [ ] Run drift detection - should show MATCH
- [ ] Delete `hosts/services/system/`

### Phase 4: Virtualisation (unused - can delete or migrate)
- [ ] Decide: migrate to modules or delete as unused?
- [ ] If migrate: create modules with options
- [ ] If delete: remove files
- [ ] Delete `hosts/services/virtualisation/`

### Phase 5: Display (mostly unused)
- [ ] `sunshine.nix` - SKIP (duplicate already in modules)
- [ ] `gnome-remote-desktop.nix` - delete as unused
- [ ] Delete `hosts/services/display/`

### Phase 6: Cleanup
- [ ] Delete empty `hosts/services/` directory
- [ ] Update `hosts/services/mounts/cifs.nix` (unused - delete or migrate)
- [ ] Run final drift detection - all hosts should MATCH
- [ ] Update hashes with `./scripts/hash-capture.sh`

## Drift Detection Strategy

After each phase:
```bash
./scripts/hash-compare.sh --summary
```

Expected: All affected hosts show **MATCH** (pure refactor).

If **DRIFT** is detected:
1. Run `./scripts/hash-compare.sh` for full nix-diff
2. Investigate what changed
3. Fix the module to be semantically equivalent

## Progress Log

| Date | Phase | Status | Notes |
|------|-------|--------|-------|
| 2026-01-19 | Analysis | COMPLETE | Identified 13 files, 4 hosts affected |
| 2026-01-19 | Phase 1 | COMPLETE | Mounts moved into modules; drift stable |
| | Phase 2 | NOT STARTED | |
| | Phase 3 | NOT STARTED | |
| | Phase 4 | NOT STARTED | |
| | Phase 5 | NOT STARTED | |
| | Phase 6 | NOT STARTED | |

## Detailed Progress

### Phase 1: Mounts
- [x] Create `modules/nixos/services/mounts/default.nix`
- [x] Create `modules/nixos/services/mounts/nfs.nix` (homelab.mounts.nfs)
- [x] Create `modules/nixos/services/mounts/nfs-local.nix` (homelab.mounts.nfsLocal)
- [x] Create `modules/nixos/services/mounts/fuse.nix` (homelab.mounts.fuse)
- [x] Create `modules/nixos/services/mounts/external.nix` (homelab.mounts.external)
- [x] Register in `modules/nixos/services/default.nix`
- [x] Update epi to use `homelab.mounts.nfs.enable = true`
- [x] Update framework to use `homelab.mounts.nfs.enable = true`
- [x] Update igpu to use new mounts modules
- [x] Update proxmox-vm to use new mounts modules
- [x] Run drift detection
- [x] Delete `hosts/services/mounts/`
