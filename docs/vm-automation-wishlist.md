# VM Automation Wishlist

Future enhancements and ideas for the VM automation system.

**Last Updated**: 2026-01-14

---

## High Priority

### 1. Evaluate OpenTofu for Proxmox

**Status**: IN PROGRESS (branch: `feature/terranix-opentofu`, post-provision flow in progress)

**Goal**: Compare a Terraform-style workflow against the current scripting. The VM automation works, but feels fragile; prototype OpenTofu with Proxmox and commit configs here to evaluate reliability and ergonomics.

**Progress**:
- [x] Added terranix to flake.nix
- [x] Created `vms/tofu/` with Nix modules that generate OpenTofu config
- [x] Consolidated VM specs into hosts.nix (single source of truth)
- [x] Added apps: `tofu-show`, `tofu-plan`, `tofu-apply`, `tofu-destroy`
- [x] Created Proxmox API token (`terraform@pve!opentofu`)
- [x] Verified `tofu-plan` generates correct plan for `dev` VM
- [x] Added NixOS template config (`vms/template/configuration.nix`)
- [x] Added nixos-generators input + `proxmox-template` package
- [x] Build/import NixOS template and update `_proxmox.templateVmid`
- [x] Validate template with guest agent + cloud-init
- [x] Ensure DHCP on ens18 in template
- [x] Test OpenTofu lifecycle (create -> no-op apply -> destroy)
- [x] Test OpenTofu import for existing VMs (dev, proxmox-vm, igpu)
- [x] Wire `tofu-output` into OpenTofu-first provisioning flow
- [ ] Make post-provision non-interactive end-to-end (SSH key path/jump host)
- [x] Test creating new VM end-to-end with qemu-guest-agent (VMID 111)

**To test from dev VM**:
```bash
cd ~/nixosconfig
export PROXMOX_VE_API_TOKEN='terraform@pve!opentofu=<token>'
tofu-show        # View generated config
tofu-plan        # Plan changes
tofu-apply       # Apply changes
```

### 2. Safe OpenTofu Apply Wrapper

**Goal**: Provide a wrapper that always runs `tofu-plan` before `tofu-apply` and discourages direct apply.

**Plan**:
- Add a wrapper command (e.g. `tofu-apply-safe`)
- The wrapper must run `tofu-plan` first and only then apply
- Update docs to emphasize using wrappers instead of direct `tofu apply`

### 3. Interactive VM Builder

**Goal**: Wizard-style VM creation with prompts

```bash
$ vm-new --interactive

🚀 Proxmox VM Provisioning Wizard

What's the VM name? my-service
What's the purpose? Running my microservice
How many CPU cores? [2] 4
How much RAM (MB)? [4096] 8192
Disk size? [20G] 32G
Storage pool? [nvmeprom] ⏎

Next available VMID: 110
Preview:
  VMID: 110
  Name: my-service
  Cores: 4
  RAM: 8192 MB (8 GB)
  Disk: 32G
  Storage: nvmeprom

Proceed? [y/N] y

📝 Creating VM definition...
📁 Creating host configuration...
🖥️  Provisioning on Proxmox...
💾 Installing NixOS...
🔐 Configuring secrets...
📚 Updating documentation...
✅ Done!

Your VM is ready:
  SSH: ssh my-service
  IP: 192.168.1.50
  Config: hosts/my-service/
```

### 2. VM Templates Library

**Goal**: Pre-configured templates for common use cases

```nix
# vms/templates.nix
{
  webserver = {
    cores = 2;
    memory = 4096;
    disk = "32G";
    services = ["Caddy" "PostgreSQL"];
    packages = ["caddy" "postgresql"];
  };

  media-server = {
    cores = 4;
    memory = 8192;
    disk = "100G";
    services = ["Jellyfin" "Sonarr" "Radarr"];
  };

  development = {
    cores = 4;
    memory = 16384;
    disk = "64G";
    services = ["Docker" "Git" "VSCode Server"];
  };

  monitoring = {
    cores = 2;
    memory = 4096;
    disk = "20G";
    services = ["Prometheus" "Grafana" "Loki"];
  };
}
```

**Usage:**

```bash
vm-new my-web --template webserver
vm-new my-media --template media-server
```

---

## Medium Priority

### 3. Resource Monitoring Dashboard

**Goal**: Overview of Proxmox resource usage

```bash
$ pve dashboard

╔═══════════════════════════════════════════════════════════╗
║              Proxmox Resource Dashboard                   ║
╠═══════════════════════════════════════════════════════════╣
║ Host: prom (192.168.1.12)                                ║
║ Storage: nvmeprom (ZFS)                                   ║
╠═══════════════════════════════════════════════════════════╣
║ CPU Usage:    [████████░░] 45% (28 cores available)      ║
║ Memory:       [██████████] 44GB / 128GB (34%)            ║
║ Storage:      [█░░░░░░░░░] 252GB / 3.78TB (6.7%)        ║
╠═══════════════════════════════════════════════════════════╣
║ Running VMs: 3 / 11 total                                ║
║                                                           ║
║ VMID │ Name      │ Status  │ CPU │ RAM   │ Disk         ║
║──────┼───────────┼─────────┼─────┼───────┼──────────────║
║  102 │ Mailstore │ Running │ 3%  │ 2GB   │ 40GB         ║
║  104 │ Doc1      │ Running │ 6%  │ 32GB  │ 250GB        ║
║  109 │ igpu      │ Running │ 2%  │ 7GB   │ passthrough  ║
╚═══════════════════════════════════════════════════════════╝
```

### 4. VM Lifecycle Management

**Goal**: Full lifecycle operations beyond provisioning

```bash
# Update a VM's NixOS configuration
pve update my-service

# Rebuild without reboot
pve rebuild my-service

# Snapshot before major changes
pve snapshot my-service "before-upgrade"

# Rollback to snapshot
pve rollback my-service "before-upgrade"

# Migrate to another host (future: multi-host support)
pve migrate my-service to prom2

# Clone a VM
pve clone my-service my-service-staging

# Destroy a VM (with confirmation)
pve destroy my-service
```

### 5. Backup Integration

**Goal**: Automated backup to Proxmox Backup Server

```nix
# In VM definition
backup = {
  enable = true;
  schedule = "daily"; # or cron format
  retention = {
    daily = 7;
    weekly = 4;
    monthly = 12;
  };
  target = "PBS_Tower";
};
```

**Commands:**

```bash
pve backup my-service                    # Manual backup
pve backup-list my-service               # List backups
pve restore my-service 2026-01-12        # Restore from backup
```

---

``
