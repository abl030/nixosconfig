# VM Provisioning on prom

**Date researched:** 2026-07-01  
**Status:** Working (Forgejo #6 closed)  
**Relates to:** [machines.md — doc1](../../machines.md), [prom-hypervisor.md](prom-hypervisor.md)

## Clean path: disko image build on doc1

The preferred way to provision a new NixOS VM on prom:

1. **Build a bootable disk image on doc1:**
   ```sh
   nix build .#nixosConfigurations.<host>.config.system.build.diskoImages
   ```
   This uses `pkgs.vmTools.runInLinuxVM` (a QEMU build VM), which requires `/dev/kvm`.
   Doc1 has `/dev/kvm` as of 2026-07-01 (`cpu: host` passthrough, Forgejo #6).

2. **Copy the image to prom and import it:**
   ```sh
   # scp/rsync the .raw image to prom
   # qm importdisk <vmid> <image.raw> <storage>
   # then attach + boot
   ```

3. On first boot the host fetches its config from Forgejo and activates — no manual
   installation steps needed.

## Prerequisites

- **prom nested virt**: `cat /sys/module/kvm_amd/parameters/nested` → must be `1` (it is; module param set permanently via Proxmox host config).
- **doc1 CPU type**: `host` (was `x86-64-v3` until 2026-07-01; change via `qm set 104 --cpu host` on prom, takes effect after VM stop+start).
- **Verify on doc1**: `ls /dev/kvm` — present after the stop+start following the CPU type change.

## Why `x86-64-v3` didn't work

`x86-64-v3` is a synthetic baseline CPU type that doesn't expose SVM (AMD's virtualisation extension) to the guest. The QEMU build VM inside doc1 therefore can't use KVM acceleration and `vmTools.runInLinuxVM` fails with a confusing kernel-modules error.

## Fallback: nixos-anywhere (and why it's painful)

If `/dev/kvm` is unavailable, you can use `nixos-anywhere` via a NixOS installer ISO, but there are several gotchas:

- **No serial getty on the minimal ISO** — `virsh console` is silent; the shell is VGA-only. Must use VNC or `virsh send-key` to drive it.
- **VNC may be broken** on the prom VM default config — test before relying on it.
- **`virsh send-key`** is fragile: a single dropped keycode silently corrupts whatever you're typing (SSH key, password). Workaround used during the servarr bootstrap: `curl`-fetch the exact key from a known server rather than typing it.
- **Installer `nix` must be current**: nixos-anywhere ≥ 1.13 probes the target with `nix config`, which didn't exist in the `nix` shipped with the NixOS 23.11 minimal ISO → `error: 'config' is not a recognised command`. Use a freshly built installer ISO (from this flake's nixpkgs) or a recent official release.

## Building a custom installer ISO (if needed)

If you need nixos-anywhere and can't use the clean path:

```nix
# In a throwaway config or flake output:
nixos-generators.nixosGenerate {
  system = "x86_64-linux";
  format = "iso";
  modules = [{
    # bake in sshd + fleet key + serial console for virsh console access
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ "<doc1 fleet key>" ];
    boot.kernelParams = [ "console=ttyS0" ];
  }];
}
```
