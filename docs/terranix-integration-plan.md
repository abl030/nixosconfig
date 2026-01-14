# Terranix Integration Plan (hosts.nix as SSOT)

**Branch**: `feature/terranix-opentofu`
**Status**: BUILDING NIXOS TEMPLATE

## Current Status

OpenTofu/Terranix implementation complete and working. Hit a blocker during testing: the Ubuntu cloud template (VMID 9002) lacks QEMU guest agent, causing OpenTofu to timeout waiting for agent response.

**Solution**: Build a proper NixOS template with qemu-guest-agent baked in.

### What's Done
- [x] hosts.nix extended with `_proxmox` config and `proxmox` attributes
- [x] Terranix modules created in `vms/tofu/`
- [x] OpenTofu apps added (`tofu-show`, `tofu-plan`, `tofu-apply`, etc.)
- [x] Proxmox API token created: `terraform@pve!opentofu`
- [x] `nix run .#tofu-plan` works and shows correct plan
- [x] Test VM (VMID 111) created successfully via OpenTofu
- [x] Existing VMs (dev, proxmox-vm, igpu) marked readonly

### Current Blocker
OpenTofu `agent.enabled = true` waits for QEMU guest agent response.
Ubuntu cloud template doesn't have qemu-guest-agent installed.
**Fix**: Create NixOS template with agent pre-installed.

---

## Phase 2: NixOS Proxmox Template

### Goal
Create a NixOS-based Proxmox template (VMA format) with:
- QEMU guest agent pre-installed and enabled
- Cloud-init for network/SSH configuration on first boot
- Auto-grow partition when disk is resized
- UEFI boot support
- Minimal footprint for fast cloning

### Approach: nixos-generators

Use [nixos-generators](https://github.com/nix-community/nixos-generators) with `proxmox` format to create a VMA file that can be imported directly into Proxmox.

**Why VMA over qcow2?**
- Native Proxmox backup format
- VM configuration (cores, memory, network) defined in Nix
- Direct import with `qmrestore`
- Cleaner than `qm importdisk`

### Files to Create

#### 1. `vms/template/configuration.nix`
Minimal NixOS configuration for the template:

```nix
{ lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # QEMU Guest Agent - critical for OpenTofu
  services.qemuGuest.enable = true;

  # Cloud-init for first-boot configuration
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Auto-expand partition when disk resized
  boot.growPartition = true;

  # GRUB bootloader (VMA uses BIOS by default)
  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  # Root filesystem by label
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Minimal packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    git
  ];

  # Allow root login for initial provisioning
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
  ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  system.stateVersion = "25.05";
}
```

#### 2. Update `flake.nix`
Add nixos-generators input and package output:

```nix
inputs.nixos-generators = {
  url = "github:nix-community/nixos-generators";
  inputs.nixpkgs.follows = "nixpkgs";
};

# In packages output:
packages.x86_64-linux.proxmox-template = nixos-generators.nixosGenerate {
  system = "x86_64-linux";
  format = "proxmox";
  modules = [ ./vms/template/configuration.nix ];
};
```

### Build & Deploy Process

```bash
# 1. Build the VMA image
nix build .#proxmox-template

# 2. Copy to Proxmox
scp result/*.vma.zst root@192.168.1.12:/var/lib/vz/dump/

# 3. Import as VM (pick a VMID in template range)
ssh root@192.168.1.12 "qmrestore /var/lib/vz/dump/nixos-*.vma.zst 9003 --unique true"

# 4. Convert to template
ssh root@192.168.1.12 "qm template 9003"

# 5. Update hosts.nix to use new template
# Change _proxmox.templateVmid from 9002 to 9003
```

### Update hosts.nix

After template is created:
```nix
_proxmox = {
  host = "192.168.1.12";
  node = "prom";
  defaultStorage = "nvmeprom";
  templateVmid = 9003;  # Changed from 9002
};
```

### Verification

1. `nix build .#proxmox-template` succeeds
2. VMA file imports to Proxmox without errors
3. Clone from template boots successfully
4. QEMU guest agent responds (check via Proxmox UI or `qm agent <vmid> ping`)
5. Cloud-init applies SSH keys and network config
6. OpenTofu can create VMs without timeout

---

## Phase 1 Reference (COMPLETE)

Phase 1 implemented OpenTofu/Terranix integration. Key files created:
- `vms/tofu/` - Terranix modules (default.nix, provider.nix, vm-resources.nix)
- `nix/tofu.nix` - Flake-parts integration
- `hosts.nix` - Extended with `_proxmox` config and `proxmox` attributes
- Apps: `tofu-show`, `tofu-plan`, `tofu-apply`, `tofu-init`, `tofu-import`

Proxmox API token: `terraform@pve!opentofu` (stored in `/tmp/pve_token` during testing)
