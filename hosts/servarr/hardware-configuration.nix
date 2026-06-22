# PLACEHOLDER — replaced at install time.
#
# This VM does not exist yet. When it's provisioned on tower (an Unraid KVM guest,
# virtio disk) via nixos-anywhere, the REAL hardware-configuration.nix — actual
# disks, filesystems by-uuid, kernel modules — is generated on the target and
# committed over this file. The minimal root + boot below exists ONLY so the flake
# evaluates cleanly; it is NOT a usable/installable layout. See Forgejo issue #1
# (build steps 4–5).
{...}: {
  boot.initrd.availableKernelModules = ["virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"];
  boot.kernelModules = [];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  swapDevices = [];
}
