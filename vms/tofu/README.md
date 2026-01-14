# OpenTofu (Proxmox)

Minimal OpenTofu/Terranix setup for Proxmox VMs (SSOT: `hosts.nix`).

## Quick use

```bash
export PROXMOX_VE_API_TOKEN="$(cat /tmp/pve_token)"
TOFU_WORKDIR=$PWD/vms/tofu/.state nix run .#tofu-plan
TOFU_WORKDIR=$PWD/vms/tofu/.state nix run .#tofu-apply
```

## Notes (learned)

- Template VMID: 9003 (NixOS VMA with qemu-guest-agent + DHCP + serial console).
- Serial console: `./scripts/pve console <vmid>` or `./vms/proxmox-ops.sh console <vmid>`.
- Post-provision applies the NixOS config and can pull IP from tofu output: `nix run .#post-provision-vm <name> <vmid>`.
- SSH host key prompts are suppressed during post-provision; set `POST_PROVISION_IDENTITY_FILE` if key auth is needed.
- Post-provision generates `hardware-configuration.nix` from the VM if it's missing.
- If you hit a stale local lock, remove `vms/tofu/.state/.terraform.tfstate.lock.info` or use `-lock=false`.
- State lives in `vms/tofu/.state` (do not commit).
- Import format is `node/vmid` (e.g., `prom/110`).

## Destroy test VM

```bash
export PROXMOX_VE_API_TOKEN="$(cat /tmp/pve_token)"
TOFU_WORKDIR=$PWD/vms/tofu/.state nix run .#tofu-destroy
```
