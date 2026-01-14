# Interactive VM Provisioner Plan

## Goal

Build a streamlined `pve new` wizard that:
- prompts for hostname and SSH alias
- defaults VMID to the next available slot (one-click accept)
- creates NixOS host config + VM definition in-repo
- provisions the VM via the existing `provision-vm` flow

## Current State (as of today)

- `scripts/pve` routes `pve new` to `nix run .#new-vm`.
- `vms/new.sh` creates `hosts/<name>/` template files and appends to `vms/definitions.nix`.
- `vms/new.sh` currently assumes name == hostname == sshAlias and asks for VMID, cores, memory, disk, storage, purpose, services.
- `pve provision` runs `nix run .#provision-vm <name>` for an existing config/definition.

## Target Behavior

Wizard flow:
1. Ask for `hostname` (lowercase, hyphen-safe).
2. Ask for `ssh alias` (short name, may differ from hostname).
3. Suggest next VMID as the default (press Enter to accept).
4. Collect VM resources (cores, RAM, disk, storage) and purpose.
5. Generate:
   - `hosts/<hostname>/` configuration files
   - managed entry in `vms/definitions.nix` (name == hostname)
   - host entry in `hosts.nix` using hostname + alias
6. Run `nix run .#provision-vm <hostname>`.

## Open Decisions

- Alias validation uses the same rules as hostname: lowercase letters, digits, hyphens.
- Wizard adds a `hosts.nix` entry immediately with a placeholder public key; `post-provision-vm` replaces the key while preserving the alias.
- `pve new` is fully interactive (no arguments).

## Work Plan

- Update `vms/new.sh` prompts and validation for hostname/alias.
- Change VMID prompt to default to the next available VMID.
- Decide how/when to update `hosts.nix` (likely add entry immediately with placeholder key).
- Update `scripts/pve` help/usage for the new behavior.
- If needed, update docs (wishlist/plan) with current flow.
