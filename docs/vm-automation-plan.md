# VM Automation

**Status**: Provisioning flow working; template boots with console access; DHCP pending
**Last Updated**: 2026-01-14

## Quick Start

```bash
# 1. Define VM in vms/definitions.nix
# 2. Create host config in hosts/{name}/
# 3. Provision:
nix run .#provision-vm <vm-name>

# 4. Integrate with fleet:
nix run .#post-provision-vm <name> <ip> <vmid>
```

## What It Does

Single command provisions a VM:
1. Clones template (currently Ubuntu 9002; moving to NixOS template with qemu-guest-agent)
2. Configures resources (CPU, RAM, disk)
3. Injects SSH keys via cloud-init
4. Installs NixOS via nixos-anywhere (two-phase)
5. Reboots and verifies SSH access

## Architecture

```
vms/
├── definitions.nix    # VM specs (source of truth)
├── lib.nix            # Nix helper functions
├── provision.sh       # Main orchestration
├── post-provision.sh  # Fleet integration
├── proxmox-ops.sh     # Proxmox SSH wrapper
└── cloudinit.nix      # Cloud-init generator
```

### VM Definition Example

```nix
managed = {
  my-service = {
    vmid = 111;
    cores = 4;
    memory = 8192;
    disk = "32G";
    nixosConfig = "my-service";
    purpose = "Running my service";
  };
};
```

### Host Config Requirements

Each VM needs `hosts/{name}/` with:
- `configuration.nix` - imports disko module
- `disko.nix` - disk partitioning (EFI + root)
- `hardware-configuration.nix` - minimal, no fileSystems
- `home.nix` - home-manager config

## Safety Features

- **Readonly VMs**: Imported VMs (104, 109) are protected
- **VMID checks**: Validates no conflicts before provisioning
- **Confirmation prompt**: Requires explicit approval
- **SSH as user**: Final access via abl030, not root

## Commands

```bash
# Provision
nix run .#provision-vm <name>

# Post-provision (fleet integration)
nix run .#post-provision-vm <name> <ip> <vmid>

# Direct Proxmox operations
./vms/proxmox-ops.sh list
./vms/proxmox-ops.sh status <vmid>
./vms/proxmox-ops.sh get-ip <vmid>
./vms/proxmox-ops.sh start|stop <vmid>
./vms/proxmox-ops.sh destroy <vmid> yes
```

## Requirements

- Template 9002: Ubuntu cloud image with UEFI (ovmf, q35, secure boot off) (current)
- Template 9003: NixOS VMA template with qemu-guest-agent (current)
- SSH access to Proxmox host (192.168.1.12)
- Disko in flake inputs
- Host entry in hosts.nix with `authorizedKeys = masterKeys`

## Next Steps

- [x] Test post-provision workflow (`nix run .#post-provision-vm`)
- [x] Verify SSH host key extraction
- [x] Verify hosts.nix update with real public key
- [x] Verify .sops.yaml age key integration
- [x] Verify secrets re-encryption
- [x] Test full fleet integration (SSH alias, secrets access)

## Known Limitations

- DHCP causes IP changes during provisioning (handled automatically)
- Single Proxmox host only

## Future Work

See `docs/vm-automation-wishlist.md` for planned enhancements.
