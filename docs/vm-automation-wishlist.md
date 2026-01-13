# VM Automation Wishlist

Future enhancements and ideas for the VM automation system.

**Status**: Ideas and proposals (not yet implemented)

**Last Updated**: 2026-01-12

---

## High Priority

### 1. CLI Wrapper for Proxmox Operations

**Goal**: Easy, typed CLI access to Proxmox operations

**Problem**: Currently need to run `./vms/proxmox-ops.sh <command>` with full paths

**Solution**: Add to shell aliases and make available system-wide

#### Implementation

**Add to NixOS/Home Manager configuration:**

```nix
# In modules or host config
environment.shellAliases = {
  # Proxmox VM operations
  pve = "proxmox-ops";
  pve-ls = "proxmox-ops list | jq -r '.[] | select(.type==\"qemu\") | [.vmid, .name, .status] | @tsv' | column -t";
  pve-status = "proxmox-ops status";
  pve-start = "proxmox-ops start";
  pve-stop = "proxmox-ops stop";
  pve-ip = "proxmox-ops get-ip";
  pve-ssh = "proxmox-ops get-ip"; # Usage: ssh root@$(pve-ssh 110)

  # Provisioning
  vm-new = "nix run .#provision-vm";
  vm-list = "nix eval --json .#vms --apply 'v: builtins.attrNames v.managed' | jq -r '.[]'";
  vm-info = "nix eval --json .#vms --apply 'v: name: v.managed.\${name}'";
};
```

**Enhanced CLI with subcommands:**

Create `scripts/pve` wrapper:

```bash
#!/usr/bin/env bash
# Enhanced Proxmox CLI

case "$1" in
  ls|list)
    proxmox-ops list | jq -r '.[] | select(.type=="qemu") |
      [.vmid, .name, .status, .maxcpu, (.maxmem/1024/1024/1024|floor)] |
      @tsv' | column -t -N "VMID,NAME,STATUS,CPU,RAM(GB)"
    ;;

  ps)
    # Show only running VMs
    proxmox-ops list | jq -r '.[] | select(.type=="qemu" and .status=="running") |
      [.vmid, .name, .cpu, (.mem/1024/1024/1024|floor)] |
      @tsv' | column -t -N "VMID,NAME,CPU%,MEM(GB)"
    ;;

  ssh)
    # SSH to VM by name or VMID
    vm="$2"
    ip=$(proxmox-ops get-ip "$vm")
    if [[ -n "$ip" ]]; then
      ssh "root@$ip"
    else
      echo "Could not get IP for VM $vm" >&2
      exit 1
    fi
    ;;

  console)
    # Open VNC console (requires vncviewer)
    vmid="$2"
    echo "Opening console for VMID $vmid..."
    ssh root@192.168.1.12 "qm terminal $vmid"
    ;;

  new)
    # Quick VM creation wizard
    shift
    nix run .#provision-vm "$@"
    ;;

  info)
    vmid="$2"
    proxmox-ops config "$vmid" | grep -E "^(cores|memory|net0|scsi0|ide2)"
    ;;

  *)
    # Pass through to proxmox-ops
    proxmox-ops "$@"
    ;;
esac
```

**Usage examples:**

```bash
pve ls                    # List all VMs in table format
pve ps                    # Show running VMs with resource usage
pve status 110            # Get status of VMID 110
pve start 110             # Start VMID 110
pve ssh 110               # SSH to VMID 110 (auto-resolve IP)
pve console 110           # Open serial console
pve new my-vm             # Provision new VM
pve info 110              # Show VM configuration
```

**Files to create:**
- `scripts/pve` - Enhanced CLI wrapper
- `modules/nixos/shell/aliases.nix` - Shell aliases module
- Update `flake.nix` to include pve in packages

**Benefits:**
- Fast, ergonomic CLI
- Integrates with existing tools (jq, column)
- Extensible with new subcommands
- Consistent with modern CLI patterns

---

## Medium Priority

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

---

### 4. VM Templates Library

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

### 5. Resource Monitoring Dashboard

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

---

### 6. VM Lifecycle Management

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

---

### 7. Backup Integration

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

## Low Priority / Future Ideas

### 8. Multi-Host Support

Support multiple Proxmox hosts in a cluster

```nix
proxmox.hosts = {
  prom = {
    ip = "192.168.1.12";
    primary = true;
  };
  prom2 = {
    ip = "192.168.1.13";
  };
};

managed.my-vm = {
  host = "prom2"; # Explicitly assign
  # Or use auto-placement based on resources
};
```

---

### 9. Cost Tracking

Track resource costs and allocation

```bash
$ pve cost-report

Monthly Resource Allocation:
  Doc1:      $45/mo (32GB RAM, 8 cores, 250GB)
  igpu:      $25/mo (8GB RAM, 8 cores)
  Mailstore: $15/mo (4GB RAM, 4 cores, 40GB)

Total: $85/mo equivalent
```

---

### 10. Auto-scaling

Dynamic resource adjustment based on load

```nix
managed.my-service = {
  autoscale = {
    enable = true;
    cpu = {
      min = 2;
      max = 8;
      threshold = 80; # percent
    };
    memory = {
      min = 4096;
      max = 16384;
      threshold = 85; # percent
    };
  };
};
```

---

### 11. Terraform Alternative

Generate Terraform configs from Nix definitions

```bash
nix build .#terraform-config

# Generates terraform files:
terraform/
  ├── main.tf
  ├── variables.tf
  └── proxmox-vms.tf
```

---

### 12. Web UI

Simple web interface for VM management

- Dashboard view
- VM provisioning form
- Real-time status updates
- Log viewing
- SSH web terminal

---

### 13. Ansible Integration

Generate Ansible playbooks from VM definitions

```bash
nix run .#generate-ansible-playbooks

# Generates:
ansible/
  └── vms/
      ├── inventory.ini
      ├── deploy-my-service.yml
      └── configure-my-service.yml
```

---

### 14. Testing Framework

Automated testing for VM configurations

```nix
tests.my-service = {
  provisioning = {
    canCreate = true;
    timeoutSeconds = 600;
  };

  configuration = {
    nixosVersion = "25.05";
    services.caddy.enable = true;
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };

  integration = [
    "curl -f http://localhost"
    "systemctl is-active caddy"
  ];
};
```

```bash
nix run .#test-vm my-service
```

---

### 15. Mobile App / Notifications

Push notifications for VM events

- VM status changes
- Resource alerts (high CPU, low disk)
- Backup completion/failures
- Security updates available

---

## Implementation Priority

**Phase 1 (Next)**: High Priority items
1. CLI Wrapper (#1)

**Phase 2**: Medium Priority
3. Interactive Builder (#3)
4. Templates Library (#4)
5. Resource Dashboard (#5)
6. Lifecycle Management (#6)

**Phase 3**: Low Priority / As Needed
7. Multi-host, Backup, Scaling, etc.

---

## Contributing Ideas

Add new wishlist items with:
- **Goal**: What are we trying to achieve?
- **Problem**: What problem does it solve?
- **Solution**: How would it work?
- **Benefits**: Why is it valuable?
- **Implementation**: Rough technical approach

---

## Notes

This wishlist reflects the evolution from basic automation to a comprehensive infrastructure management system. Not all items will be implemented - prioritize based on actual needs and pain points.

The core goal remains: **Declarative, safe, ergonomic VM management**.
