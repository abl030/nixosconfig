{
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (modulesPath + "/virtualisation/proxmox-image.nix")
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
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];
  systemd.services."serial-getty@ttyS0".enable = true;
  networking.useNetworkd = true;
  systemd.network.networks."10-ens18" = {
    matchConfig.Name = "ens18";
    networkConfig.DHCP = "ipv4";
  };

  # Root filesystem by label
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Minimal packages
  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    vim
    curl
    git
  ]);

  # Allow root login for initial provisioning
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
  ];
  users.users.root.initialHashedPassword = "$6$58mDYkJdHY9JTiTU$whCjz4eG3T9jPajUIlhqqBJ9qzqZM7xY91ylSy.WC2MkR.ckExn0aNRMM0XNX1LKxIXL/VJe/3.oizq2S6cvA0"; # temp123

  # Proxmox image settings (replaces nixos-generators format = "proxmox")
  proxmox.qemuConf = {
    cores = 2;
    memory = 2048;
    bios = "ovmf";
    net0 = "virtio=00:00:00:00:00:00,bridge=vmbr0,firewall=1";
  };

  system.stateVersion = "25.05";
}
