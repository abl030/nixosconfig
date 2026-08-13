{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    # We add virtio drivers here so the initrd works for BOTH Bare Metal (ignores them) and VM (uses them)
    initrd.availableKernelModules = ["nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" "virtio_blk" "virtio_pci" "virtio_scsi"];
    initrd.kernelModules = [];
    # epimetheus is an AMD Ryzen 7 5700X. The generated default said
    # "kvm-intel", so every boot logged `kvm_intel: VMX not supported by CPU N`
    # and /dev/kvm was never created -- which silently demoted QEMU/NixOS VM
    # checks (cratedigger's moduleVm) to TCG emulation, ~5x slower.
    #
    # NOTE: this alone does not materialise /dev/kvm. SVM is currently
    # disabled AND locked in firmware (MSR_VM_CR=0x18: SVMDIS=1, LOCK=1), so
    # kvm-amd refuses to load with "SVM not supported by CPU 0". Enable
    # "SVM Mode" in the Gigabyte B450 I AORUS PRO WIFI BIOS
    # (Tweaker -> Advanced CPU Settings) and cold-boot; this line is what
    # makes the module load once firmware allows it.
    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/225830e2-ef4b-40cf-bda0-cf359cc6d0f7";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/AA7D-E617";
    fsType = "vfat";
    options = ["fmask=0077" "dmask=0077"];
  };

  swapDevices = [];

  # Enables DHCP on each ethernet and wireless interface.
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
