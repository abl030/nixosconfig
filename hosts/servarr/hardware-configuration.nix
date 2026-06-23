# Hardware profile for the servarr VM (Unraid KVM, q35, SATA disk = /dev/sda).
# Kernel modules taken from `nixos-generate-config` on the live host. Filesystems
# are NOT declared here: disko (./disko.nix) owns / and /boot, and the tower NFS
# library mount lives in configuration.nix (the doc2 disko-host pattern).
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd.availableKernelModules = ["ahci" "xhci_pci" "sd_mod"];
    initrd.kernelModules = [];
    kernelModules = ["kvm-intel"];
    extraModulePackages = [];
  };

  swapDevices = [];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
