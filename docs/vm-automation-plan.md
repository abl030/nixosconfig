# VM Automation

**Status**: Template 9003 verified; OpenTofu managing dev/proxmox-vm/igpu; post-provision flow verified
**Last Updated**: 2026-01-15

## Quick Start

```bash
# 1. Define VM in hosts.nix (proxmox attrs) + host config in hosts/{name}/
# 2. OpenTofu creates the VM from template 9003:
# Store token in ~/.pve_token (format: user@realm!tokenid=secret)
pve apply

# 3. Integrate with fleet (generates hardware config, applies NixOS, then secrets/hosts):
pve integrate <name> <ip> <vmid>
```

## What It Does

OpenTofu-first provisioning:
1. OpenTofu clones template 9003 and applies resources
2. Cloud-init injects SSH keys (template behavior)
3. Post-provision generates hardware config (if missing), applies NixOS config, and integrates into fleet

Current blocker:
- None.

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

Note: `provision.sh` is legacy; OpenTofu is the primary creation path.

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

- **Readonly VMs**: If marked readonly in `vms/definitions.nix`, wrapper blocks changes
- **VMID checks**: Validates no conflicts before provisioning
- **Confirmation prompt**: Requires explicit approval
- **SSH as user**: Final access via abl030, not root

## Commands

```bash
# OpenTofu plan/apply (wrapper loads ~/.pve_token)
pve plan
pve apply

# Post-provision (fleet integration)
pve integrate <name> <ip> <vmid>

# Direct Proxmox operations
./vms/proxmox-ops.sh list
./vms/proxmox-ops.sh status <vmid>
./vms/proxmox-ops.sh get-ip <vmid>
./vms/proxmox-ops.sh start|stop <vmid>
./vms/proxmox-ops.sh destroy <vmid> yes
```

## Requirements

- Template 9003: NixOS VMA template with qemu-guest-agent (OpenTofu path)
- Template 9002: Ubuntu cloud image with UEFI (legacy path)
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
