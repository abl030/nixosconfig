# Hardware profile for the servarr VM (Unraid KVM / virtio). Filesystems are
# provided declaratively by disko (./disko.nix) — intentionally none here.
# Real install (nixos-anywhere) uses the disko layout; if a generated
# hardware-configuration.nix adds host-specific kernel modules post-install,
# fold them in here.
{...}: {
  boot.initrd.availableKernelModules = ["virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"];
  boot.kernelModules = [];
  swapDevices = [];
}
