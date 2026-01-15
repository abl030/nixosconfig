# Terranix Integration Plan (hosts.nix as SSOT)

**Branch**: `feature/terranix-opentofu`
**Status**: TEMPLATE VERIFIED; IMPORTS COMPLETE; POST-PROVISION FLOW IN PROGRESS (IP CHANGE HANDLING ADDED, NEEDS RETEST)

## Current Status

OpenTofu/Terranix implementation complete and working.

**Current state**: NixOS template VMA built and imported as VMID 9003; `_proxmox.templateVmid` updated. Serial console access works via wrapper, DHCP is working, OpenTofu created VM 111 successfully, and existing VMs (dev, proxmox-vm, igpu) are imported and managed.

### What's Done
- [x] hosts.nix extended with `_proxmox` config and `proxmox` attributes
- [x] Terranix modules created in `vms/tofu/`
- [x] OpenTofu apps added (`tofu-show`, `tofu-plan`, `tofu-apply`, etc.)
- [x] Proxmox API token created: `terraform@pve!opentofu`
- [x] `nix run .#tofu-plan` works and shows correct plan
- [x] Test VM (VMID 111) created successfully via OpenTofu
- [x] Existing VMs (dev, proxmox-vm, igpu) imported into OpenTofu state
- [x] Timeout metadata applied (`timeout_move_disk`) to imported VMs
- [x] NixOS template config added (`vms/template/configuration.nix`)
- [x] nixos-generators input + `proxmox-template` package wired
- [x] VMA built and imported on Proxmox (VMID 9003)
- [x] Template converted in Proxmox (`qm template 9003`)
- [x] `_proxmox.templateVmid` updated to 9003
- [x] Serial console streaming via wrapper (`./vms/proxmox-ops.sh console <vmid>`)
- [x] Temp root password baked in (`temp123`) for console access
- [x] DHCP enabled on ens18 in template
- [x] OpenTofu create succeeds using template 9003
- [x] OpenTofu plan is clean (no drift)

### Current Blocker
Post-provision still needs a clean end-to-end run after handling IP changes.

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

#### 1. `vms/template/configuration.nix` (DONE)
Minimal NixOS configuration for the template:

```nix
{modulesPath, pkgs, ...}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  services = {
    # QEMU Guest Agent - critical for OpenTofu
    qemuGuest.enable = true;

    # Cloud-init for first-boot configuration
    cloud-init = {
      enable = true;
      network.enable = true;
    };

    openssh = {
      enable = true;
      settings.PermitRootLogin = "yes";
    };
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

  system.stateVersion = "25.05";
}
```

#### 2. Update flake outputs (DONE)
Add nixos-generators input and expose `proxmox-template`:

```nix
inputs.nixos-generators = {
  url = "github:nix-community/nixos-generators";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Per-system arg and package output (via nix/devshell.nix)
_module.args.nixosGenerate = inputs.nixos-generators.nixosGenerate;
proxmoxTemplate = nixosGenerate { system = pkgs.system; format = "proxmox"; modules = [ ../vms/template/configuration.nix ]; };
packages.proxmox-template = proxmoxTemplate;
```

### Build & Deploy Process (DONE)

```bash
# 1. Build the VMA image (done)
nix build .#proxmox-template

# 2. Copy to Proxmox (done)
scp result/*.vma.zst root@192.168.1.12:/var/lib/vz/dump/

# 3. Import as VM (done)
ssh root@192.168.1.12 "qmrestore /var/lib/vz/dump/nixos-*.vma.zst 9003 --unique true --storage nvmeprom"

# 4. Convert to template (done)
ssh root@192.168.1.12 "qm template 9003"

# 5. Update hosts.nix to use new template (done)
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

### Verification (DONE)

1. Template boots with DHCP on ens18
2. QEMU guest agent responds (verified via systemd service on VM 111)
3. Cloud-init applies SSH keys and network config
4. OpenTofu can create VMs without timeout

### Next Steps

- [x] Validate full OpenTofu lifecycle (create -> no-op apply -> destroy)
- [x] Test importing existing VMs into state (`tofu import`)
- [x] Wire `tofu-output` into provisioning/automation where useful

---

## Phase 3: OpenTofu-First Provisioning

### Goal
Move provisioning to an OpenTofu-first workflow:
1) OpenTofu creates a blank NixOS VM from template 9003
2) Deploy NixOS configuration onto the VM
3) Integrate into fleet (keys/secrets/hosts.nix updates)

### Plan
- [ ] Replace provisioning flow with OpenTofu-created VM as the starting point
- [x] Use `tofu-output` (or state) as the source of VM IPs
- [ ] Keep post-provision integration (`post-provision-vm`) as the final step
- [ ] Update docs and scripts to remove reliance on `vms/provision.sh`
- [ ] Always run a verification step before moving on (e.g. `tofu-plan`, `tofu-output`, or status checks)
- [ ] Always run `tofu-plan` before any `tofu-apply`
- [x] Detect IP change during `nixos-rebuild` and re-resolve via guest agent
- [x] Retry IP resolution with timeout after DHCP/network restart
- [x] Add `initialHashedPassword` for `test` host (temp123) in `hosts.nix`
- [ ] Add/maintain interactive `pve new` VM wizard as the default entrypoint for new hosts (use `test` config as the default template)

### Current State
- `post-provision-vm <name> <vmid>` resolves IP from `tofu-output`, applies NixOS via `nixos-rebuild`, and handles DHCP IP changes.
- Hardware config is generated on first run and now prompts before overwriting.
- Test VM (111) is 8GB RAM / 50G disk; disk auto-expanded on boot.
- Root SSH is disabled in final configs; use `abl030` after the rebuild.
- Tailscale auth automation is in progress (see `docs/tailscale-auth-plan.md`).
- Next step: wire the Tailscale OAuth flow into post-provision and test end-to-end using VM IP.

### What We Learned
- Rebuild-only flow requires the VM’s generated `hardware-configuration.nix`.
- Non-interactive SSH is mandatory for automation; prompts must be avoided.

---

## Phase 1 Reference (COMPLETE)

Phase 1 implemented OpenTofu/Terranix integration. Key files created:
- `vms/tofu/` - Terranix modules (default.nix, provider.nix, vm-resources.nix)
- `nix/tofu.nix` - Flake-parts integration
- `hosts.nix` - Extended with `_proxmox` config and `proxmox` attributes
- Apps: `tofu-show`, `tofu-plan`, `tofu-apply`, `tofu-init`, `tofu-import`

Proxmox API token: `terraform@pve!opentofu` (stored in `/tmp/pve_token` during testing)
