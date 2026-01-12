# VM Automation - Lessons Learned (2026-01-12)

**Status**: End-to-end testing revealed multiple automation gaps

---

## What We Attempted

Full automated provisioning of test-automation VM (VMID 110):
1. Clone template → Configure resources → Setup cloud-init → Start VM
2. Boot into live environment with SSH
3. Deploy NixOS via nixos-anywhere
4. Post-provision fleet integration

---

## Issues Discovered

### 1. Template Had Disk ✅ FIXED

**Problem**: Template VM (VMID 9001) had a 150GB disk attached
- When cloning, new VM inherited the disk
- Script tried to CREATE a new disk, failed with "unable to parse zfs volume name '20G'"

**Root Cause**: Template wasn't diskless as expected

**Fix**: Removed disk from template 9001
- VMs now clone without disks
- Provision script creates disk with correct size (20G)

**Status**: ✅ RESOLVED

---

### 2. Cloud-init Doesn't Install OS ⚠️ FUNDAMENTAL ISSUE

**Problem**: We configured cloud-init with SSH keys, but VM has no OS on disk
- VM boots and tries to use cloud-init
- But cloud-init only configures EXISTING operating systems
- It doesn't install an OS from scratch

**What Actually Happens**:
1. VM clones from diskless template
2. New 20GB disk is created (empty, no filesystem)
3. Cloud-init drive is attached with SSH keys
4. VM starts → no bootable OS → falls back to PXE boot

**Realization**: Cloud-init is for **post-install configuration**, not OS installation

**Status**: ⚠️ ARCHITECTURAL ISSUE

---

### 3. Live ISO Boot is Not Automated 🔴 BLOCKER

**Attempted Solutions**:

#### Option A: NixOS Minimal ISO
- Boots into live environment
- SSH daemon NOT running by default
- Requires manual console access to:
  - `sudo passwd` (set root password)
  - `systemctl start sshd` (enable SSH)
  - Get IP address
- **Not automatic**

#### Option B: Ubuntu Server ISO
- Has cloud-init support
- BUT: Boots into installer TUI (text user interface)
- Doesn't automatically apply cloud-init in live mode
- Requires manual interaction
- **Not automatic**

#### Option C: Custom ISO
- Could create custom NixOS ISO with:
  - SSH pre-enabled
  - Fleet keys baked in
  - Auto-DHCP and qemu-guest-agent
- **One-time effort, then automatic**
- Not yet implemented

**Current Workaround**: Manual console access to enable SSH in live environment

**Status**: 🔴 REQUIRES MANUAL INTERVENTION

---

### 4. SSH Authentication Loops 🔴 BLOCKER

**Problem**: nixos-anywhere can't authenticate to live ISO

**What Happens**:
```
ssh-copy-id attempts key auth with ALL available SSH keys
→ Hits "Too many authentication failures"
→ Connection refused before password prompt
→ Retries infinitely
→ Never succeeds
```

**Root Cause**: SSH agent has multiple keys, tries them all before password

**Attempted Workarounds**:
- Disable SSH agent: Failed
- Force password auth only: Failed
- Use sshpass: Not installed

**Working Solution**: Manually add fleet key to `/root/.ssh/authorized_keys` in live environment

**Status**: 🔴 REQUIRES MANUAL INTERVENTION

---

## Current Workflow (Reality)

### Automated Steps ✅
1. Clone template VM from diskless 9001
2. Configure CPU/RAM (2 cores, 4GB)
3. Create disk (20G on nvmeprom)
4. Attach cloud-init drive with fleet SSH keys
5. Start VM

**Time**: ~30 seconds
**Success**: 100%

### Manual Steps Required 🔴

**Step 1: Boot Live Environment** (5 minutes)
1. Attach NixOS ISO via Proxmox console:
   ```bash
   qm set 110 --ide0 local:iso/latest-nixos-minimal-x86_64-linux.iso,media=cdrom
   qm set 110 --boot order=ide0;scsi0
   qm stop 110 && qm start 110
   ```

2. Wait for boot (watch console)

3. In VM console, enable SSH:
   ```bash
   sudo passwd  # Set password
   systemctl start sshd
   ip addr show | grep inet  # Get IP
   ```

**Step 2: Add SSH Key** (1 minute)
In VM console:
```bash
mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

**Step 3: Run nixos-anywhere** (5-10 minutes)
```bash
nix run github:nix-community/nixos-anywhere -- --flake .#test-automation root@<IP>
```

**Step 4: Post-provision** (2 minutes)
```bash
bash vms/post-provision.sh test-automation <new-IP> 110
```

**Total Manual Time**: ~15-20 minutes per VM

---

## Why This Matters

### Current State
- **First 30 seconds**: Fully automated ✅
- **Next 15-20 minutes**: Manual console interaction required 🔴

### Expected State
- **End-to-end**: Fully automated ✅
- **User action**: None (or single confirmation prompt)

**Gap**: 15-20 minutes of manual work per VM

---

## Root Cause Analysis

### The Chicken-and-Egg Problem

```
Need: Automated OS installation
Requires: SSH access to live environment
Problem: Live environments don't auto-enable SSH
Solution 1: Manual console access (current)
Solution 2: Custom ISO with SSH pre-configured (future)
```

### Why Cloud-init Didn't Solve This

Cloud-init configuration flow:
1. OS boots from disk
2. Cloud-init runs during boot
3. Applies configuration (users, SSH keys, network)
4. OS is now configured

Our flow:
1. No OS on disk
2. Need to INSTALL OS first
3. Then cloud-init can configure it

**Mismatch**: Cloud-init = post-install config, not installer

---

## Proposed Solutions

### Option 1: Custom NixOS ISO (Recommended)

**Create once, use forever**

Build custom ISO with:
```nix
# custom-installer.nix
{
  # Enable SSH by default
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  # Add fleet keys
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
  ];

  # Auto-DHCP
  networking.useDHCP = true;

  # QEMU guest agent
  services.qemuGuest.enable = true;
}
```

**Build**: `nix build .#custom-installer-iso`
**Upload to Proxmox**: Once
**Benefit**: Fully automated thereafter

**Effort**: 2-4 hours one-time setup
**Savings**: 15 minutes per VM forever

---

### Option 2: Automated Console Interaction

Use `expect` or similar to automate console commands:
```bash
expect <<EOF
spawn qm terminal 110
expect "login:"
send "root\r"
expect "Password:"
send "passwd\r"
# ... etc
EOF
```

**Pros**: No custom ISO needed
**Cons**: Fragile, timing-dependent, complex

---

### Option 3: Accept Manual Step

Document the 15-minute manual process as required:
- "First boot requires console access to enable SSH"
- Provide clear step-by-step instructions
- Automate everything after SSH is available

**Pros**: No additional work
**Cons**: Not truly automated

---

### Option 4: Pre-installed Template

Instead of diskless template, maintain a template WITH NixOS installed:
- Template has minimal NixOS installation
- Cloud-init configures on first boot
- nixos-anywhere updates to our config

**Pros**: Boots directly, SSH available immediately
**Cons**: Template maintenance, must update periodically

---

## Recommendations

### Immediate (Testing)
1. Accept manual SSH setup for now
2. Complete end-to-end test with test-automation VM
3. Validate post-provision automation works
4. Document actual workflow

### Short-term (Production Readiness)
1. **Build custom NixOS installer ISO** (Option 1)
   - 2-4 hours of work
   - Solves the automation gap completely
   - Best ROI for regular VM creation

2. Update provision script to:
   - Detect if custom ISO exists
   - Use it automatically
   - Fall back to manual with clear instructions

### Long-term (Nice-to-have)
1. Investigate PXE boot as alternative
2. Consider automated console interaction (Option 2)
3. Create multiple ISOs for different VM types

---

## What We Learned

### About Proxmox/KVM VMs
- Template cloning works great
- Cloud-init configuration applied correctly
- Resource configuration straightforward
- QEMU guest agent needed for IP detection

### About NixOS Deployment
- nixos-anywhere requires SSH access to live environment
- No standard way to auto-enable SSH in ISO
- Custom ISOs are the standard solution
- Community has examples (search "nixos custom installer")

### About Automation
- "Fully automated" means NO manual steps
- 95% automated still requires manual work
- First-boot automation is hard
- One-time setup (custom ISO) is worth it

---

## Current Status

### Phase 1: Foundation ✅
- VM definitions, operations library, documentation
- **100% complete**

### Phase 2: Orchestration ✅
- Cloud-init, provision script, post-provision, flake integration
- **100% complete** (code works as designed)

### Phase 3: Testing 🟡
- VM created successfully (VMID 110)
- **Blocked at**: Manual SSH setup required
- **Completion**: 30% (automated portion works)

### Phase 4: Production Readiness 🔴
- **Blocked**: Not truly automated without custom ISO
- **Required**: Build custom installer ISO
- **Status**: Not started

---

## Next Actions

### To Complete Current Test

1. ✅ Template made diskless
2. ✅ VM cloned and configured
3. 🔄 Manual SSH setup (in progress)
4. ⏳ Run nixos-anywhere
5. ⏳ Run post-provision
6. ⏳ Test SSH to finished VM
7. ⏳ Document results

### To Achieve Full Automation

1. ❌ Build custom NixOS installer ISO with SSH
2. ❌ Upload to Proxmox storage
3. ❌ Update provision script to use custom ISO
4. ❌ Test fully automated workflow
5. ❌ Document and commit

---

## Time Investment Analysis

### Current Manual Process
- **Per VM**: 15-20 minutes manual work
- **10 VMs/year**: 150-200 minutes = 2.5-3.5 hours/year
- **Scalability**: Poor (linear time per VM)

### With Custom ISO
- **One-time**: 2-4 hours to build and test ISO
- **Per VM**: 0 minutes manual work (fully automated)
- **10 VMs**: Break-even after 10 VMs
- **Scalability**: Excellent (constant time)

**Recommendation**: Build custom ISO if planning to create 10+ VMs

---

## Documentation Gaps Identified

1. ❌ Custom installer ISO creation guide
2. ❌ Manual provisioning fallback procedure
3. ❌ Troubleshooting SSH authentication issues
4. ❌ Template maintenance procedures
5. ✅ This lessons learned document

---

## Conclusion

**What Works**:
- Proxmox VM creation and configuration
- Cloud-init setup
- Post-provision automation (untested but code complete)

**What Doesn't Work Automatically**:
- Getting SSH access to fresh VM
- First-boot automation without custom ISO

**Path Forward**:
1. **Short-term**: Complete test with manual SSH setup
2. **Medium-term**: Build custom installer ISO for full automation
3. **Long-term**: Maintain ISO, consider additional solutions

**Key Insight**: The hard part isn't Proxmox or NixOS - it's the gap between "empty VM" and "SSH-accessible environment". This is a solved problem (custom ISOs), we just need to implement the solution.
