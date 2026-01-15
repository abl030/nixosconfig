# VM Automation (OpenTofu + Proxmox)

This directory contains the OpenTofu/Terranix VM automation stack for the
Proxmox fleet. The single source of truth for VM specs lives in `hosts.nix`
under each host's `proxmox` attribute and the `_proxmox` top-level config.

## State Management

OpenTofu state is stored locally in `vms/tofu/.state` (not committed). If the
state is missing, OpenTofu will assume nothing exists and plan to recreate
resources. Keep the state directory intact or migrate it to a shared backend.

## Primary Workflows (via `pve`)

### Create a new VM

1. `pve new`
2. Review the OpenTofu plan when prompted.
3. Confirm apply to create the VM.
4. Run `pve integrate <name> <ip> <vmid>` to finalize NixOS config + secrets.

`pve new` copies base config files from `hosts/vm_base/` into `hosts/<name>/`
(`configuration.nix` and `home.nix`). The `hardware-configuration.nix` file is
generated during `pve integrate` by running `nixos-generate-config` over SSH
and saving the output into `hosts/<name>/`.

### Integrate a VM into the fleet

`pve integrate <name> <ip> <vmid>`

This runs post-provisioning: generates hardware config if missing, applies
NixOS, enrolls the VM in Tailscale using the stored credentials, updates
`hosts.nix`, updates `.sops.yaml`, and re-encrypts secrets. After the rebuild,
SSH from the machine that ran `pve integrate` should work without extra steps.

### Remove a VM

`pve remove <name>`

Removes host config and sops keys, updates secrets, then runs OpenTofu plan and
apply to destroy the VM resource.

## OpenTofu Commands

All OpenTofu apps are exposed via `pve`:

- `pve plan`   -> `nix run .#tofu-plan`
- `pve apply`  -> `nix run .#tofu-apply`
- `pve output` -> `nix run .#tofu-output`

## Supporting Files

- `vms/tofu/`: Terranix modules and OpenTofu configuration generation
- `vms/proxmox-ops.sh`: Proxmox SSH wrapper used by `pve`
- `vms/post-provision.sh`: Fleet integration steps
- `vms/package.nix`: Nix packaging that exposes the VM scripts as `nix run .#...` apps.

## `pve` vs `proxmox-ops`

`pve` is the high-level CLI. It wraps:
- OpenTofu apps (`nix run .#tofu-plan`, `nix run .#tofu-apply`, etc.)
- Post-provision workflow (`nix run .#post-provision-vm`)
- Direct Proxmox operations by calling `proxmox-ops`

`proxmox-ops` is the low-level SSH wrapper around Proxmox `qm`/`pvesh` commands.
Use `proxmox-ops` for direct VM operations; use `pve` for end-to-end workflows.
