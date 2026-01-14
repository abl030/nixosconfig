{
  modulesPath,
  pkgs,
  ...
}: {
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
    devices = ["nodev"];
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
