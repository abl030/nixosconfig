# VM Automation Plan

**Goal**: Fully declarative, Nix-based VM provisioning for Proxmox infrastructure

**Status**: Phase 2 (Orchestration) complete - Ready for testing

**Last Updated**: 2026-01-12

---

## Vision

Add a new VM to Proxmox by:
1. Defining it in `vms/definitions.nix`
2. Creating minimal host config in `hosts/{name}/`
3. Running: `nix run .#provision-vm {name}`
4. Everything else automated: clone, configure, install NixOS, update secrets, commit

---

## Architecture

### Declarative VM Definitions

**File**: `vms/definitions.nix`

```
├── proxmox: Connection config (host, node, storage)
├── imported: Pre-existing VMs (doc1, igp) - read-only documentation
├── managed: VMs provisioned by automation
└── template: Base template (NixosServerBlank) for cloning
```

**Safety Model**:
- Imported VMs have `readonly = true` flag
- Operations on imported VMs fail with clear errors
- Prevents accidental modification of production systems

### Three-Layer Library

**1. Pure Nix Functions** (`vms/lib.nix`)
- VM definition validation
- VMID allocation and conflict detection
- Safety checks (readonly enforcement)
- Configuration helpers

**2. SSH Operations Wrapper** (`vms/proxmox-ops.sh`)
- Bash wrapper around `qm` commands
- Executes via SSH to Proxmox host
- Built-in safety checks before destructive operations
- Commands: clone, configure, start, stop, get-ip, etc.

**3. Nix Package** (`vms/proxmox.nix`)
- Bundles script with dependencies (ssh, jq, awk)
- Available as `proxmox-ops` command
- Integrated into flake packages

### Knowledge Base

**File**: `docs/machines.md`

Auto-generated/maintained documentation:
- Infrastructure overview
- VM inventory with specs
- Service listings
- Network configuration
- Quick command reference
- VMID allocation strategy

---

## Implementation Status

### ✅ Phase 1: Foundation (COMPLETED)

**Completed 2026-01-12**

- [x] Explored existing Proxmox infrastructure
- [x] Documented current VMs (Doc1, igpu)
- [x] Created VM definition structure
- [x] Built Nix helper library (lib.nix)
- [x] Implemented Proxmox operations wrapper (proxmox-ops.sh)
- [x] Created comprehensive knowledge base (machines.md)
- [x] Documented plan and wishlist

**Deliverables**:
- `vms/definitions.nix` - VM definition structure
- `vms/lib.nix` - Pure Nix helper functions
- `vms/proxmox-ops.sh` - SSH-based operations wrapper
- `vms/proxmox.nix` - Nix package wrapper
- `docs/machines.md` - Knowledge base
- `docs/vm-automation-plan.md` - This file

**Testing**:
```bash
./vms/proxmox-ops.sh list          # List all VMs
./vms/proxmox-ops.sh status 104    # Check Doc1 status
./vms/proxmox-ops.sh stop 104      # Should fail (readonly VM)
```

---

### ✅ Phase 2: Orchestration (COMPLETED)

**Completed**: 2026-01-12

**Target**: End-to-end VM provisioning

#### Tasks

- [x] **Cloud-init Configuration Generator** (`vms/cloudinit.nix`)
  - Generate cloud-init user-data with SSH keys
  - Extract fleet SSH keys from hosts.nix
  - Format keys for Proxmox cloud-init
  - Generate network configuration (DHCP by default)
  - Used for initial VM bootstrapping

- [x] **Main Orchestration Script** (`vms/provision.sh`)
  - Read VM definition from `vms/definitions.nix`
  - Validate configuration and check for conflicts
  - Clone from template (VMID 9001)
  - Configure resources (CPU, RAM, disk)
  - Attach cloud-init drive with SSH keys
  - Start VM and wait for network
  - Provides instructions for NixOS deployment

- [x] **Post-Provisioning Automation** (`vms/post-provision.sh`)
  - Extract SSH host key from new VM
  - Update `hosts.nix` with new entry
  - Convert SSH key to age key
  - Update `.sops.yaml` with new age key
  - Re-encrypt all secrets: `sops updatekeys --yes`
  - Update `docs/machines.md` with new VM info (TODO: auto-update)
  - Git commit all changes

- [x] **Integration with Flake** (`vms/package.nix`, `nix/devshell.nix`)
  - Add `provision-vm` to flake apps
  - Add `post-provision-vm` to flake apps
  - Add `proxmox-ops` to flake packages
  - Include all tools in dev shell
  - Wire up dependencies

**Deliverables**:
- `vms/cloudinit.nix` - Cloud-init configuration generator
- `vms/provision.sh` - Main provisioning orchestration
- `vms/post-provision.sh` - Post-provisioning fleet integration
- `vms/package.nix` - Nix packages for all tools
- Updated `nix/devshell.nix` - Integrated into flake

**Available Commands**:
```bash
nix run .#provision-vm <vm-name>        # Provision new VM
nix run .#post-provision-vm <name> <ip> <vmid>  # Integrate with fleet
nix run .#proxmox-ops <command>         # Direct Proxmox operations
```

#### Architecture

```
provision-vm <vm-name>
  ↓
┌─────────────────────────────────────┐
│ 1. Load & Validate Definition       │
│    - vms/lib.nix helpers            │
│    - Check VMID availability        │
│    - Ensure VM is in 'managed'      │
│    - Verify hosts/{name}/ exists    │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│ 2. Proxmox VM Creation              │
│    - Clone template (9001)          │
│    - Set cores, memory              │
│    - Create disk (nvmeprom)         │
│    - Add cloud-init drive           │
│    - Inject SSH keys                │
│    - Start VM                       │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│ 3. Network Bootstrap                │
│    - Wait for VM to get DHCP        │
│    - Query IP via qemu-guest-agent  │
│    - Wait for SSH to be ready       │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│ 4. NixOS Installation               │
│    - nixos-anywhere --flake .#{name}│
│    - Installs from hosts/{name}/    │
│    - Reboots into NixOS             │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│ 5. Fleet Integration                │
│    - SSH to new VM                  │
│    - Extract /etc/ssh/..._key.pub   │
│    - Update hosts.nix               │
│    - Generate age key (ssh-to-age)  │
│    - Update .sops.yaml              │
│    - sops updatekeys --yes          │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│ 6. Documentation & Commit           │
│    - Update docs/machines.md        │
│    - Git add all changes            │
│    - Commit with conventional format│
│    - Optional: push to remote       │
└─────────────────────────────────────┘
```

---

### 📋 Phase 3: Testing & Refinement (PLANNED)

**Target**: Validate end-to-end workflow

#### Tasks

- [ ] Test VM creation with minimal config
- [ ] Verify secret management integration
- [ ] Test VMID conflict detection
- [ ] Test readonly VM protection
- [ ] Validate knowledge base updates
- [ ] Test git commit automation
- [ ] Document any edge cases or issues

#### Test VM Definition

```nix
# Add to vms/definitions.nix managed section
test-automation = {
  vmid = 110;
  cores = 2;
  memory = 4096;
  disk = "20G";
  storage = "nvmeprom";
  nixosConfig = "test-automation";
  purpose = "Testing automated provisioning system";
  services = [];
};
```

#### Test Checklist

- [ ] Clone succeeds from template
- [ ] Resources configured correctly
- [ ] Cloud-init works (SSH access)
- [ ] nixos-anywhere deploys successfully
- [ ] SSH key extraction works
- [ ] hosts.nix updated correctly
- [ ] Secrets re-encrypted
- [ ] machines.md updated
- [ ] Git commit created
- [ ] VM accessible via SSH alias

---

### 🎯 Phase 4: Production Readiness (FUTURE)

**Target**: Polish and extend functionality

#### Planned Enhancements

- [ ] Dry-run mode for all operations
- [ ] Rollback capability for failed provisions
- [ ] Parallel VM provisioning
- [ ] VM migration between hosts
- [ ] Snapshot management
- [ ] Backup integration (PBS)
- [ ] Resource monitoring and alerts
- [ ] Cost/resource tracking
- [ ] VM lifecycle management (update, rebuild, destroy)

#### CLI Improvements

See `docs/vm-automation-wishlist.md` for detailed future work.

---

## Usage Guide

### Adding a New VM (Once Complete)

**1. Define VM in vms/definitions.nix**

```nix
managed = {
  my-new-service = {
    vmid = 110;
    cores = 4;
    memory = 8192;
    disk = "32G";
    nixosConfig = "my-new-service";
    purpose = "Running my awesome service";
    services = ["MyApp" "Database"];
  };
};
```

**2. Create Host Configuration**

```bash
mkdir -p hosts/my-new-service
cp -r hosts/proxmox-vm/* hosts/my-new-service/
# Edit configuration.nix and home.nix
```

**3. Run Provisioning**

```bash
nix run .#provision-vm my-new-service
```

**4. Done!**

VM is created, NixOS installed, secrets configured, everything committed.

---

## Safety Guarantees

### Readonly VM Protection

**Imported VMs** (Doc1, igpu) are protected:
- `readonly = true` flag in definitions
- Operations checked before execution
- Clear error messages if attempted
- No accidental destruction

### VMID Collision Detection

- Check Proxmox for existing VMIDs
- Check definitions.nix for conflicts
- Suggest next available VMID
- Fail safely if collision detected

### Git-Based Audit Trail

- All changes committed to git
- Conventional commit messages
- Full history of infrastructure changes
- Easy rollback if needed

### Validation Pipeline

- VM definition validation (lib.nix)
- Configuration file existence checks
- SSH key format verification
- Resource allocation sanity checks

---

## File Structure

```
nixosconfig/
├── vms/
│   ├── definitions.nix      # VM definitions (source of truth)
│   ├── lib.nix              # Pure Nix helper functions
│   ├── proxmox-ops.sh       # SSH-based operations wrapper
│   ├── proxmox.nix          # Nix package wrapper
│   └── provision.nix        # Main orchestration (TODO)
├── docs/
│   ├── machines.md          # Knowledge base (auto-maintained)
│   ├── vm-automation-plan.md         # This file
│   └── vm-automation-wishlist.md     # Future enhancements (TODO)
├── hosts/
│   ├── proxmox-vm/          # Doc1 config (VMID 104)
│   ├── igpu/                # igpu config (VMID 109)
│   └── <new-vm>/            # New VM configs
├── hosts.nix                # Fleet SSH keys and identity
├── .sops.yaml               # Secret encryption keys
└── flake.nix                # Flake integration
```

---

## Dependencies

### Runtime
- `openssh` - SSH client for Proxmox connections
- `jq` - JSON parsing for Proxmox API responses
- `gawk` - Text processing
- `coreutils` - Standard utilities
- `nixos-anywhere` - NixOS remote installation
- `sops` - Secret management
- `age` - Encryption backend

### Proxmox Requirements
- SSH key-based authentication configured
- User: root (or user with qm permissions)
- Template VM created (VMID 9001)
- Storage pool available (nvmeprom)

---

## Known Limitations

### Current State
- Manual cloud-init ISO creation (automation TODO)
- No dry-run mode yet
- No rollback capability
- Single Proxmox host only (prom)
- No parallel provisioning

### Design Decisions
- SSH-based operations (not REST API)
  - Simpler authentication
  - No API token management
  - Reuses existing SSH setup
- Cloud-init for bootstrapping (not PXE)
  - Faster than full network boot
  - Template-based approach
- Template cloning (not from-scratch creation)
  - Faster provisioning
  - Consistent base configuration

---

## Success Criteria

### Phase 2 Complete When:
- [ ] Can provision VM with single command
- [ ] NixOS automatically installed
- [ ] Secrets automatically configured
- [ ] Documentation automatically updated
- [ ] Changes automatically committed
- [ ] VM accessible via SSH alias

### Production Ready When:
- [ ] All phases complete
- [ ] Tested with multiple VMs
- [ ] Documentation comprehensive
- [ ] Error handling robust
- [ ] Rollback capability exists
- [ ] Team can use independently

---

## References

- **Proxmox Documentation**: `ansible/prom_prox/readme.md`
- **Host Definitions**: `hosts.nix`
- **Secret Management**: `secrets/readme.md`
- **Infrastructure Plans**: `docs/plan.md`, `docs/wishlist.md`
- **nixos-anywhere**: https://github.com/nix-community/nixos-anywhere

---

## Timeline

- **2026-01-12**: Phase 1 completed (foundation)
- **2026-01-XX**: Phase 2 target (orchestration)
- **2026-01-XX**: Phase 3 target (testing)
- **2026-XX-XX**: Phase 4 target (production)

---

## Notes

This is a living document. Update as implementation progresses.
Maintain alignment with actual code state.
