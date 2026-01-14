# VM Automation - Lessons Learned

**Last Updated**: 2026-01-13

## The Working Solution

**Template 9002** (Ubuntu cloud image with UEFI) + **two-phase nixos-anywhere** deployment.

### Provisioning Flow

```
Clone 9002 → cloud-init boots Ubuntu → get IP A
    ↓
nixos-anywhere --phases kexec → IP changes to B (kills process)
    ↓
Find new IP via MAC lookup
    ↓
nixos-anywhere --phases disko,install root@IP_B
    ↓
Reboot → NixOS boots → IP C → SSH as abl030
```

## Key Issues & Solutions

### 1. Template Must Use UEFI

**Problem**: SeaBIOS template + EFI partition in disko = boot failure

**Solution**: Template 9002 with UEFI:
```bash
qm create 9002 --bios ovmf --machine q35 \
  --efidisk0 nvmeprom:1,format=raw,efitype=4m,pre-enrolled-keys=0
```

### 2. IP Changes After Kexec

**Problem**: NixOS installer gets different DHCP IP, nixos-anywhere hangs

**Solution**: Two-phase deployment:
1. `--phases kexec` only (process will hang after kexec)
2. Kill hung process, find new IP via MAC/ARP lookup
3. `--phases disko,install` on new IP

Built into `provision.sh` - handles automatically.

### 3. SSH Access Pattern

**Problem**: Root SSH would expose root access fleet-wide

**Solution**: Use abl030 user (created by base profile):
- Base profile sets up user with SSH keys from hosts.nix
- provision.sh verifies SSH as abl030, not root
- Root only accessible during cloud-init phase (for nixos-anywhere)
- Automation VMs can use a temporary password hash via `initialHashedPassword` in hosts.nix.

### 4. IP Discovery Without Guest Agent

Guest agent not running on first boot. Use MAC/ARP fallback:
```bash
# Built into proxmox-ops.sh get-ip
# Flushes stale ARP, does ping sweep, finds IP by MAC
```

### 5. Disko Required

nixos-anywhere needs disko. Each host needs:
- `disko.nix` with EFI + root partitions
- Import `inputs.disko.nixosModules.disko` in configuration.nix
- Remove `fileSystems` from hardware-configuration.nix

## What's Automated

| Step | Status |
|------|--------|
| Clone template | Automated |
| Configure resources | Automated |
| Cloud-init SSH keys | Automated |
| Find IP (MAC/ARP) | Automated |
| NixOS install (two-phase) | Automated |
| Reboot | Automated |
| Final SSH verification | Automated |
| Post-provision | Manual |

## Commands

```bash
# Full provision
./vms/provision.sh <vm-name>

# Manual operations
./vms/proxmox-ops.sh clone 9002 <vmid> <name> nvmeprom
./vms/proxmox-ops.sh configure <vmid> <cores> <memory>
./vms/proxmox-ops.sh resize <vmid> scsi0 <size>
./vms/proxmox-ops.sh get-ip <vmid>
./vms/proxmox-ops.sh wait-ssh <ip> [timeout] [user]
```
