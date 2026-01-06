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

      # CHANGED: Must be true for the laptop to wake up at 01:00
      wakeOnUpdate = true;

      rebootOnKernelUpdate = false;

      # Smart Update Gates
      checkWifi = ["theblackduck"];
    };
  };

  boot = {
    extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom="AU"
    '';
    kernelPackages = pkgs.linuxPackages_latest;
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    resumeDevice = "/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00";

    kernelParams = [
      "amdgpu.sg_display=0"
      "amdgpu.gpu_recovery=1"
      "resume=/dev/disk/by-uuid/eced9c09-7bfe-4db4-ad4b-54f155dd1b00"
      "rtc_cmos.use_acpi_alarm=1"
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

  systemd.services = {
    NetworkManager-wait-online.enable = pkgs.lib.mkForce false;
    tailscaled.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 3;
    polkit.serviceConfig.TimeoutStopSec = pkgs.lib.mkForce 5;
  };

  # Fix for fprintd keeping device busy
  systemd.services.fprintd = {
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "simple";
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
