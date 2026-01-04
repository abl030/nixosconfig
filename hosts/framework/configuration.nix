{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs.nix
    ../common/desktop.nix
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ../framework/sleep-then-hibernate.nix
    ../services/system/remote_desktop_nosleep.nix
  ];

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
      wakeOnUpdate = false;
      rebootOnKernelUpdate = false;
    };
  };

  boot = {
    extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom="AU"
    '';
    kernelPackages = pkgs.linuxPackages_latest;
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    # We keep this for the initrd generator
    resumeDevice = "/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00";

    # FORCE the resume argument and the GPU fix directly into the kernel command line
    # Kernel Parameters
    kernelParams = [
      # 1. PREVENT: Fix the memory race condition on Hibernate/Resume
      "amdgpu.sg_display=0"

      # 2. PARACHUTE: If the GPU crashes, reset it instead of freezing the OS
      "amdgpu.gpu_recovery=1"

      # 3. RESUME: Explicitly tell the kernel where to look for the hibernation image
      "resume=/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00"
    ];
  };

  services = {
    fwupd = {
      enable = true;
      extraRemotes = ["lvfs-testing"];
    };
    xserver = {
      enable = true;
      xkb.layout = "us";
    };
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;

    # Audio
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    openssh.enable = true;
  };

  hardware.wirelessRegulatoryDatabase = true;
  hardware.graphics.enable = true;

  networking.networkmanager.enable = true;

  # FIX: Prevent system hangs during rebuild/shutdown
  systemd.services = {
    NetworkManager-wait-online.enable = pkgs.lib.mkForce false;
    tailscaled.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 3;
    polkit.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 5;
  };

  security.rtkit.enable = true;

  users.users.abl030 = {
    extraGroups = ["libvertd" "dialout"];
  };

  environment.systemPackages = with pkgs; [
    gh
    gnome-remote-desktop
    dmidecode
    fprintd
  ];

  programs.firefox.enable = true;

  system.stateVersion = "24.05";
}
