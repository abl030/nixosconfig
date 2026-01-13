# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a flake-based NixOS and Home Manager configuration managing a homelab infrastructure. The repository uses a custom configuration factory pattern to generate both full NixOS systems and standalone Home Manager configurations from a single host definition file (`hosts.nix`).

## Core Architecture

### Configuration Factory Pattern

The heart of this repo is `nix/lib.nix`, which provides two factory functions:
- `mkNixosSystem`: Creates full NixOS configurations (machines with `configurationFile` in `hosts.nix`)
- `mkHomeConfiguration`: Creates standalone Home Manager configs (machines without `configurationFile`)

Both functions automatically inject:
- Standard module sets (NixOS, Home Manager, Sops)
- Special arguments: `inputs`, `hostname`, `allHosts`, `system`, `flake-root`, `hostConfig`
- Global overlays and registry settings

### Host Definition System

`hosts.nix` is the **single source of truth** for fleet identity and trust. Each host entry defines:
- **Identity**: hostname, sshAlias, user, homeDirectory
- **Trust**: publicKey (SSH host key), authorizedKeys (who can access)
- **Config**: paths to configuration.nix and home.nix files
- Optional: initialHashedPassword, sudoPasswordless

The presence of `configurationFile` determines whether a host is a full NixOS system or Home Manager-only.

### Module Structure

**NixOS modules** (`modules/nixos/`):
- `profiles/base.nix`: Base profile automatically imported for all NixOS hosts
- Custom modules under `homelab.*` namespace:
  - `homelab.ssh`: SSH server configuration
  - `homelab.tailscale`: Tailscale mesh networking
  - `homelab.update`: Automated system updates and garbage collection
  - `homelab.nixCaches`: Nix cache client configuration
  - `homelab.cache`: Nix cache server (for doc1)
  - `homelab.ci`: CI/CD including GitHub Actions runners and rolling flake updates

**Home Manager modules** (`modules/home-manager/`):
- Registered in `modules/home-manager/default.nix`
- Display, shell, services, and multimedia configurations
- Automatically imported for both NixOS (via HM module) and standalone HM configs

## VM Automation

### VM Definitions

`vms/definitions.nix` contains:
- **imported**: Pre-existing VMs (readonly=true) - documented but not managed by automation
- **managed**: VMs provisioned and managed through automation
- **template**: Base template (VMID 9002) for cloning

### Proxmox Operations

**CRITICAL**: Always use `vms/proxmox-ops.sh` wrapper script, NEVER run Proxmox commands directly via SSH.

The wrapper protects production VMs (104, 109, 110) from accidental modification by checking the readonly flag before ANY destructive operation.

### Provisioning Workflow

1. Define VM in `vms/definitions.nix` under `managed`
2. Create host configuration in `hosts/{name}/`:
   - `configuration.nix` (NixOS config)
   - `disko.nix` (disk partitioning)
   - `hardware-configuration.nix` (hardware detection)
   - `home.nix` (Home Manager config)
3. Add placeholder entry to `hosts.nix` with temporary publicKey
4. Run: `nix run .#provision-vm <vm-name>`
5. After provisioning, run: `nix run .#post-provision-vm <vm-name> <IP> <VMID>`
6. Deploy with secrets: `nixos-rebuild switch --flake .#<vm-name> --target-host <vm-name>`

## Secrets Management

Uses **Sops-nix** with **Age** encryption:
- Secrets encrypted against SSH host keys (converted to Age keys)
- Bootstrap paradox: Host keys decrypt master user key on boot
- Configuration: `secrets/.sops.yaml`
- When adding a new host:
  1. Get SSH host key from `/etc/ssh/ssh_host_ed25519_key.pub`
  2. Convert to Age key: `cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age`
  3. Add Age key to `secrets/.sops.yaml`
  4. Re-encrypt: `sops updatekeys --yes <file>` for each secret file

## Quality Gates

**CRITICAL: The `check` command MUST pass before committing.**

The `check` command runs a comprehensive quality gate that includes:
1. Format checking (Alejandra)
2. Linting (deadnix for unused code)
3. Linting (statix for style issues)
4. Flake checks (builds all configurations)

```bash
# Run all checks before committing
check

# If formatting issues are found
nix fmt

# The check command will exit with error if any check fails
```

## Common Commands

### Building and Deploying

```bash
# Build configuration
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel

# Deploy to local machine
sudo nixos-rebuild switch --flake .#<hostname>

# Deploy to remote machine
nixos-rebuild switch --flake .#<hostname> --target-host <hostname>

# Build from GitHub (no local checkout needed)
nixos-rebuild switch --flake github:abl030/nixosconfig#<hostname>

# Test configuration without switching
nix flake check

# Show what would change
nixos-rebuild build --flake .#<hostname>
nix run nixpkgs#nvd -- diff /run/current-system ./result
```

### Development Tools

```bash
# Format all Nix files
nix fmt

# Check formatting without writing
nix run .#fmt-nix -- --check

# Show formatting diffs
nix run .#fmt-nix -- --diff

# Lint with deadnix + statix
nix run .#lint-nix

# Enter dev shell
nix develop
```

### VM Operations

```bash
# List all VMs
./vms/proxmox-ops.sh list

# Get VM status
./vms/proxmox-ops.sh status <vmid>

# Start/stop VM (protected - checks readonly flag)
./vms/proxmox-ops.sh start <vmid>
./vms/proxmox-ops.sh stop <vmid>

# Provision new VM
nix run .#provision-vm <vm-name>

# Post-provision (fleet integration)
nix run .#post-provision-vm <vm-name> <IP> <VMID>

# Get next available VMID
./vms/proxmox-ops.sh next-vmid
```

### Secrets Management

```bash
# Edit encrypted file
sops secrets/path/to/file.env

# Add new host to secrets
cd secrets
find . -type f \( -name "*.env" -o -name "*.yaml" -o -name "ssh_key_*" \) | \
  while read file; do sops updatekeys --yes "$file"; done
```

## Fleet Overview

### Current Hosts

- **epimetheus**: Main workstation (desktop, full NixOS)
- **framework**: Laptop (Framework 13, full NixOS with hibernation)
- **caddy**: Server/container (Home Manager only)
- **wsl**: WSL instance (full NixOS with NixOS-WSL)
- **proxmox-vm** (doc1): Main services VM on Proxmox (VMID 104, imported)
- **igpu**: Media transcoding with AMD iGPU passthrough (VMID 109, imported)
- **dev**: Development VM (VMID 110, managed)

### Proxmox Infrastructure

- **Primary Host**: prom (192.168.1.12) - AMD 9950X with iGPU
- **Default Storage**: nvmeprom (ZFS pool, 3.53 TB available)
- **VMID Ranges**:
  - 100-199: Production VMs
  - 200-299: LXC containers
  - 9000-9999: Templates

## Key Design Patterns

### Base Profile Application

Every NixOS host automatically gets `modules/nixos/profiles/base.nix` which:
- Sets hostname from `hostConfig.hostname`
- Configures locales (Australia/Perth, en_GB)
- Enables flakes and auto-optimise-store
- Enables `homelab.*` defaults (SSH, Tailscale, updates, nix caches)
- Creates user from `hostConfig.user` with authorized keys
- Adds standard packages (git, vim, wget, home-manager, nvd)
- Shows nvd diff on system activation

All settings use `lib.mkDefault` so individual hosts can override.

### Special Arguments Available in Modules

- `inputs`: All flake inputs (nixpkgs, home-manager, sops-nix, etc.)
- `hostname`: Current host's name (from hosts.nix key)
- `hostConfig`: Full host definition from hosts.nix
- `allHosts`: All hosts from hosts.nix (for cross-host reference)
- `flake-root`: The flake root (self)
- `system`: "x86_64-linux"

### Docker Compose Integration

Docker services defined as Nix files in `docker/*/docker-compose.nix` - these are referenced by doc1 VM configuration.

## Important Files

- `flake.nix`: Entry point, defines outputs and imports
- `hosts.nix`: Single source of truth for fleet identity
- `nix/lib.nix`: Configuration factory functions
- `modules/nixos/profiles/base.nix`: Base profile for all NixOS hosts
- `vms/definitions.nix`: VM specifications and inventory
- `vms/proxmox-ops.sh`: Safe Proxmox operations wrapper
- `secrets/.sops.yaml`: Age key configuration for secrets

## CI/CD

- **GitHub Actions**: Daily `flake.lock` updates with auto-merge
- **Quality Gate**: All changes must pass `nix flake check`
- **Auto-updates**: Enabled on doc1 and igpu (03:00 daily with GC at 03:30)
- **Rolling Updates**: doc1 has rolling flake updates enabled via `homelab.ci.rollingFlakeUpdate`

## Special Configurations

### doc1 (Main Services VM)
- Serves as Nix cache server (nixcache.ablz.au)
- Runs GitHub Actions runner (proxmox-bastion)
- Hosts 20+ Docker services
- MTU 1400 for Tailscale compatibility

### igpu (Media Transcoding)
- AMD 9950X iGPU passthrough
- Latest kernel for GPU support
- Increased inotify watches (2,097,152)
- Vendor-reset DKMS module on Proxmox host

### framework (Laptop)
- Sleep-then-hibernate configuration
- Fingerprint reader support
- Power management optimizations
