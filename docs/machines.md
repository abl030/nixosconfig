# Machine Inventory

Infrastructure as Code knowledge base for homelab VMs and hosts.

**Last Updated**: 2026-01-12
**Proxmox Version**: PVE 9 (assumed based on patch playbooks)

---

## Infrastructure Overview

### Proxmox Hosts

| Host | IP | Role | Hardware | Status |
|------|-----------|------|----------|--------|
| **prom** | 192.168.1.12 | Primary VM host | AMD 9950X with iGPU | Active |
| epi-prox | 192.168.1.5 | Emergency/backup | Intel Arc A310 GPU | Inactive (bare metal NixOS) |
| pbs-tower | 192.168.1.30 | Backup server | N/A | Running Unraid |

**Current Primary Host**: `prom` (192.168.1.12)

### Storage Configuration

| Storage | Type | Capacity | Used | Available | Usage % | Notes |
|---------|------|----------|------|-----------|---------|-------|
| **nvmeprom** | ZFS | 3.78 TB | 252 GB | 3.53 TB | 6.67% | **Default for VMs** - 3x NVMe with 1 disk redundancy |
| PBS_Tower | PBS | 15.6 TB | 14.0 TB | 1.67 TB | 89.34% | Proxmox Backup Server |
| Tower | CIFS | 15.6 TB | 14.0 TB | 1.67 TB | 89.34% | Unraid share mount |
| Test | LVM-thin | 1.92 TB | 583 GB | 1.34 TB | 30.39% | Test storage pool |
| local | DIR | 219 GB | 9 GB | 210 GB | 4.18% | Local host storage |

---

## Virtual Machines

### Quick Reference

| VMID | Name | Status | Cores | RAM | Disk | Host | Managed |
|------|------|--------|-------|-----|------|------|---------|
| 100 | windowstest | Stopped | 16 | 32 GB | 50 GB | prom | Manual |
| 102 | Mailstore | Running | 4 | 4 GB | 40 GB | prom | Manual |
| 103 | BaldursGate | Stopped | 28 | 32 GB | - | prom | Manual |
| **104** | **Doc1** | **Running** | **8** | **32 GB** | **250 GB** | **prom** | **Imported** |
| 105 | KindgomComeD2 | Stopped | 28 | 32 GB | - | prom | Manual |
| 107 | WindowsGamingBlank | Stopped | 28 | 32 GB | 300 GB | prom | Template |
| 108 | Batocera | Stopped | 16 | 4 GB | - | prom | Manual |
| **109** | **igpu** | **Running** | **8** | **8 GB** | **passthrough** | **prom** | **Imported** |
| 9000 | coreostemplate | Stopped | 2 | 2 GB | 10 GB | prom | Template |
| **9001** | **NixosServerBlank** | **Stopped** | **8** | **8 GB** | **-** | **prom** | **Template** |

**Legend**:
- **Imported**: Pre-existing VMs documented in `hosts.nix` (managed by OpenTofu when enabled)
- **Managed**: VMs created and managed by automation
- **Template**: Available for cloning
- **Manual**: Outside automation scope

### LXC Containers

| VMID | Name | Status | Purpose |
|------|------|--------|---------|
| 201 | proxmox-datacenter-manager | Stopped | Datacenter management tools |
| 202 | managerio | Stopped | Management interface |
| 203 | ollama | Stopped | LLM inference |

---

## NixOS VMs (Tracked in hosts.nix)

### Doc1 (VMID 104)
**Import Note**: This VM is documented as imported/read-only in automation

- **Hostname**: `proxmox-vm` (in hosts.nix)
- **SSH Alias**: `doc1`
- **Status**: Running
- **Purpose**: Main services VM - Docker workloads and CI/CD
- **Config Path**: `hosts/proxmox-vm/`

**Specifications**:
- 8 CPU cores
- 32 GB RAM
- 250 GB disk (nvmeprom)
- MTU: 1400 on ens18
- Firewall: Disabled

**Services Running**:
- **Network**: Tailscale + Caddy (reverse proxy)
- **Media & Files**: Immich, Audiobookshelf, StirlingPDF, WebDAV
- **Infrastructure**: NetBoot (PXE), Kopia (backups), GitHub Actions runner
- **Monitoring**: Uptime Kuma, Smokeping, Tautulli, Domain Monitor
- **Applications**: Paperless, Atuin, Mealie, Jdownloader2, Invoices, Youtarr, Music

**Special Configuration**:
- Serves as Nix cache server (nixcache.ablz.au)
- Rolling flake updates enabled via CI module
- Daily auto-updates at 03:00 with GC at 03:30
- Reboot on kernel updates enabled

**NixOS Configuration Highlights**:
```nix
services.qemuGuest.enable = true;
virtualisation.docker.enable = true;
networking.interfaces.ens18.mtu = 1400;
networking.firewall.enable = false;
homelab.cache.enable = true;
homelab.ci.rollingFlakeUpdate.enable = true;
homelab.services.githubRunner.enable = true;
```

---

### igpu (VMID 109)
**Import Note**: This VM is documented as imported/read-only in automation

- **Hostname**: `igpu` (in hosts.nix)
- **SSH Alias**: `igp`
- **Status**: Running
- **Purpose**: Media transcoding with AMD iGPU passthrough
- **Config Path**: `hosts/igpu/`

**Specifications**:
- 8 CPU cores
- 8 GB RAM (~8096 MB)
- No dedicated disk (uses passthrough storage)
- Storage backend: nvmeprom

**Hardware**:
- **GPU**: AMD 9950X integrated graphics (iGPU passthrough)
- **Kernel**: `linuxPackages_latest` for AMD support
- **Host Setup**: vendor-reset DKMS module for GPU reset
- **vBIOS**: `/usr/share/kvm/vbios_9950x.rom` on Proxmox host
- **User Groups**: docker, video, render (for GPU access)

**Services Running**:
- Jellyfin (media server)
- Plex
- Tdarr (transcoding pipeline)
- Management stack for iGPU monitoring

**Monitoring Tools**:
- libva-utils (VA-API testing)
- radeontop (GPU monitoring)
- nvtop (AMD variant)

**Special Configuration**:
- inotify watches increased to 2,097,152
- Auto-updates enabled with reboot on kernel update
- Kernel parameter: `cgroup_disable=hugetlb`

**NixOS Configuration Highlights**:
```nix
boot.kernelPackages = pkgs.linuxPackages_latest;
boot.kernel.sysctl."fs.inotify.max_user_watches" = 2097152;
hardware.graphics.enable = true;
hardware.cpu.amd.updateMicrocode = true;
services.qemuGuest.enable = true;
users.users.abl030.extraGroups = ["docker" "video" "render"];
```

---

## VM Templates

### NixosServerBlank (VMID 9001)
**Primary template for provisioning new NixOS VMs**

- **Base Specs**: 8 cores, 8 GB RAM
- **Usage**: Clone this template when creating new VMs
- **Status**: Stopped (templates should remain stopped)
- **Storage**: nvmeprom

**Cloning Command** (manual):
```bash
ssh root@192.168.1.12 'qm clone 9001 <NEW_VMID> --name <VM_NAME> --full --storage nvmeprom'
```

### coreostemplate (VMID 9000)
- CoreOS template (not actively used)
- 2 cores, 2 GB RAM, 10 GB disk

### WindowsGamingBlank (VMID 107)
- Windows 11 template with VirtIO drivers
- 28 cores, 32 GB RAM, 300 GB disk
- See: `ansible/prom_prox/automate_windows/readme.md`

---

## Proxmox Host Configuration

### prom (192.168.1.12)

**Node**: `prom`
**Hardware**: AMD 9950X with integrated graphics
**Role**: Primary VM host

**GPU Passthrough**:
- AMD iGPU (9950X) passed through to VMID 109 (igpu)
- Uses vendor-reset DKMS module for GPU reset support
- vBIOS file cached: `/usr/share/kvm/vbios_9950x.rom`

**BIOS Settings** (for iGPU passthrough):
- SVM Mode: Enabled
- Above 4G Decoding: Enabled
- IOMMU: Enabled

**Setup Playbooks** (in `ansible/prom_prox/`):
1. `passthrough_igpu2.yml` - Downloads vBIOS files
2. `patch_igpu_reset_PVE9.yml` - Installs vendor-reset DKMS module
3. `nvme.yml` - NVMe power management (APST, PCIe ASPM)

**Storage**:
- Primary: nvmeprom ZFS pool (3x NVMe, 1 disk redundancy)
- Import command: `zpool import -f nvmeprom`

**SSH Access**:
- User: root
- Passwordless SSH enabled (key-based)
- Connection: `ssh root@192.168.1.12`

---

## Network Configuration

### IP Addressing
- **Scheme**: DHCP + Tailscale overlay
- **DNS**: pfSense handles local hostname resolution
- **Access**: VMs accessible via hostname.local or Tailscale names

### VM Network Settings
- Bridge: vmbr0 (default)
- MTU: 1400 (for Doc1, Tailscale requirement)
- Firewall: Disabled on VMs (handled by pfSense)

---

## Automation Status

### Current State
- **Imported VMs**: 2 (Doc1, igpu) - documented but not managed
- **Managed VMs**: 0 - none provisioned via automation yet
- **Source of Truth**: `hosts.nix` (`proxmox` blocks)

### Provisioning Workflow (OpenTofu)
1. Run `pve new` to create the host entry and base configs
2. Review the OpenTofu plan, then apply
3. Run `pve integrate <name> <ip> <vmid>` for fleet integration

---

## VMID Allocation Strategy

| Range | Purpose | Notes |
|-------|---------|-------|
| 100-199 | Production VMs | Active services and workloads |
| 200-299 | LXC Containers | Linux containers |
| 9000-9999 | Templates | VM templates for cloning |

**Next Available VMID**: 110 (for production VMs)

---

## Quick Commands

### Proxmox Management
```bash
# List all VMs
ssh root@192.168.1.12 'qm list'

# Get VM status
ssh root@192.168.1.12 'qm status <VMID>'

# Storage status
ssh root@192.168.1.12 'pvesm status'

# Clone template
ssh root@192.168.1.12 'qm clone 9001 <NEW_VMID> --name <NAME> --full --storage nvmeprom'

# Get VM config
ssh root@192.168.1.12 'qm config <VMID>'
```

### NixOS Deployment
```bash
# Deploy to existing VM
nixos-rebuild switch --flake .#<hostname> --target-host <hostname>

# Deploy via nixos-anywhere (fresh install)
nixos-anywhere --flake .#<hostname> root@<vm-ip>
```

### Fleet Management
```bash
# SSH aliases (from hosts.nix)
ssh doc1  # Doc1 VM (VMID 104)
ssh igp   # igpu VM (VMID 109)
ssh epi   # Epimetheus workstation
ssh fra   # Framework laptop
```

---

## References

- **Proxmox Documentation**: `ansible/prom_prox/readme.md`
- **GPU Passthrough**: See playbooks in `ansible/prom_prox/`
- **Host Definitions**: `hosts.nix`
- **VM Definitions**: `hosts.nix`
- **Infrastructure Plans**: `docs/plan.md`, `docs/wishlist.md`
- **Secrets Management**: `secrets/readme.md`

---

**Note**: This file is intended to be auto-generated/updated by the VM provisioning system. Manual edits should be documented in git commits.
