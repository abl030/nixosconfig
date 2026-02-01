{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader = {
    systemd-boot.enable = false;
    efi.canTouchEfiVariables = false;
    grub = {
      enable = true;
      devices = ["nodev"];
    };
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
    };
  };

  # Enable QEMU guest agent for Proxmox integration
  services.qemuGuest.enable = true;

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    htop
    vim
    git
    curl
    jq
  ]);

  system.stateVersion = "25.05";
}
