# VM Automation - Lessons Learned

## Current Working Approach

**Template 9002** (Ubuntu cloud image) solves the chicken-and-egg problem:
- Cloud-init needs an OS to configure
- Ubuntu cloud image provides that OS
- nixos-anywhere then replaces it with NixOS

### Provisioning Flow
```
Clone template 9002 → Resize disk → Inject SSH keys via cloud-init → Start → Find IP → SSH in → nixos-anywhere
```

---

## Key Learnings

### 1. Template Must Have an OS

**Wrong**: Blank UEFI template (9001) - cloud-init can't configure nothing
**Right**: Ubuntu cloud image (9002) - boots, runs cloud-init, accepts SSH

Template setup:
```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create 9002 --name "ubuntu-cloud-template" ...
qm importdisk 9002 noble-server-cloudimg-amd64.img nvmeprom
qm set 9002 --ide2 nvmeprom:cloudinit --agent enabled=1
qm template 9002
```

### 2. IP Discovery Without Guest Agent

Guest agent isn't running on first boot. Use MAC/ARP fallback:

```bash
# Get VM MAC
MAC=$(qm config 110 | grep -oP 'virtio=\K[^,]+')

# Ping sweep to populate ARP
for i in $(seq 1 254); do ping -c1 -W1 192.168.1.$i &>/dev/null & done; wait

# Find IP by MAC
ip neigh | grep -i "$MAC"
```

This is now built into `proxmox-ops.sh get-ip`.

### 3. Cloud Image Auth

- Ubuntu cloud images have **no default password**
- SSH key injection is the only access method
- Console login requires explicitly setting `--cipassword`

### 4. Resize, Don't Create Disk

When cloning from cloud image:
- Template already has a disk (3.5GB)
- Use `qm resize` not `qm set --scsi0`

### 5. nixos-anywhere Requires Disko

nixos-anywhere needs disko for disk partitioning. Each host config needs:

1. Add disko to flake inputs:
```nix
disko = {
  url = "github:nix-community/disko";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

2. Create `hosts/<name>/disko.nix`:
```nix
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = { size = "512M"; type = "EF00"; content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; }; };
        root = { size = "100%"; content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; }; };
      };
    };
  };
}
```

3. Import in configuration.nix:
```nix
{pkgs, inputs, ...}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];
  # ...
}
```

4. Remove `fileSystems` from hardware-configuration.nix (disko handles it)

**TODO**: Automate disko.nix generation during `provision-vm`

### 6. Template VGA Setting

Ubuntu cloud template (9002) has `vga: serial0` for serial console. After nixos-anywhere, this can cause console access issues.

**Fix**: Set VGA to standard after provisioning:
```bash
qm set <vmid> --vga std
```

**TODO**: Add this to provision script or update template.

### 7. Sops Secrets on New VMs

nixos-anywhere shows sops errors on first install - this is expected:
```
Cannot read ssh key '/etc/ssh/ssh_host_ed25519_key': no such file or directory
```

The VM doesn't have its SSH host key in `.sops.yaml` yet. Run post-provision to:
1. Extract SSH host key
2. Add to `.sops.yaml`
3. Re-encrypt secrets

---

## Commands Reference

```bash
# Provision VM
./vms/provision.sh test-automation

# Or manually:
./vms/proxmox-ops.sh clone 9002 110 test-automation nvmeprom
./vms/proxmox-ops.sh configure 110 2 4096
./vms/proxmox-ops.sh resize 110 scsi0 20G
./vms/proxmox-ops.sh cloudinit-config 110 "$SSH_KEYS"
./vms/proxmox-ops.sh start 110

# Get IP (uses MAC/ARP fallback automatically)
./vms/proxmox-ops.sh get-ip 110

# Deploy NixOS
nixos-anywhere --flake .#test-automation root@<ip>
```

---

## What's Automated vs Manual

| Step | Status |
|------|--------|
| Clone template | Automated |
| Configure resources | Automated |
| Resize disk | Automated |
| Inject SSH keys | Automated |
| Start VM | Automated |
| Find IP | Automated (MAC/ARP) |
| SSH access | Automated (fleet keys) |
| NixOS install | Manual command |
| Post-provision | Manual command |

**Total manual work**: 2 commands after VM boots

---

## Historical Context

Previously tried blank template + custom ISO approach. Problems:
- Blank template = no OS for cloud-init to configure
- NixOS ISO = SSH not enabled by default
- Required console access to enable SSH manually

**Solution**: Ubuntu cloud image template sidesteps all of this.

---

## Current Status (2026-01-12)

**VM 110 (test-automation)**: NixOS installed via nixos-anywhere, but VM fails to boot.

### What Worked
- Template 9002 clone and cloud-init SSH key injection
- MAC/ARP IP discovery (192.168.1.151)
- SSH to Ubuntu cloud image
- nixos-anywhere kexec and NixOS installation completed
- nixos-anywhere reported "installation finished!" and "### Done! ###"

### What's Broken
- **VM stuck at "booting from hard-disk"** - never gets past bootloader
- Likely disko/boot partition configuration issue
- May be EFI vs BIOS mismatch, or partition table issue

### Next Steps (Tomorrow)
1. Investigate disko.nix config - check EFI partition setup
2. Verify template 9002 boot settings (UEFI vs SeaBIOS)
3. Check if boot partition was created correctly
4. May need to adjust disko config or template settings
5. Consider testing disko config in a throwaway VM first
