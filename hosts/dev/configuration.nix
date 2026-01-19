{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    pve = {
      enable = true;
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

  # Development tools
  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    htop
    vim
    git
    curl
    jq
    # OpenTofu/Terranix testing
    opentofu
    sops
    age
  ]);

  system.stateVersion = "25.05";
}
