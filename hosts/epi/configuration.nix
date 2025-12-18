{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs.nix
    ../services/nvidia/intel.nix
    ../common/configuration.nix
    ../common/desktop.nix
    ../services/system/remote_desktop_nosleep.nix
  ];

  # --- INCEPTION MODE: VM Specialisation ---
  specialisation = {
    vm.configuration = {
      system.nixos.tags = ["vm"];
      services.qemuGuest.enable = true;
      system.activationScripts.update-bootloader = ''
        echo "Updating Virtual EFI Bootloader..."
        /nix/var/nix/profiles/system/bin/switch-to-configuration boot
      '';
    };
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    hyprland = {
      enable = true;
    };
    sunshine = {
      enable = true;
    };
    vnc = {
      enable = true;
      secure = true;
      openFirewall = false;
    };
    tailscale = {
      enable = true;
      tpmOverride = true;
    };
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = false;
      trim = true;
    };
  };

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    # --- KERNEL PARAMS ---
    kernelParams = [
      "i915.force_probe=56a6"
      "i915.enable_guc=3"
      "nvme_core.default_ps_max_latency_us=0"
      "video=HDMI-A-2:1920x1080@75e"
      "video=DP-3:2560x1440@144e"
      "video=HDMI-A-3:1920x1080@60e"
    ];

    blacklistedKernelModules = [
      "xe"
    ];

    initrd.kernelModules = [
      "i915"
    ];
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    bluetooth.enable = true;
    graphics = {
      enable = true;
    };
    logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };
  };

  networking = {
    hostName = "epimetheus";
    networkmanager.enable = true;
    firewall = {
      allowedTCPPorts = [3389 3390];
      allowedUDPPorts = [5140];
    };
  };

  services = {
    udev.extraRules = ''
      # Block internal Intel Bluetooth (8087:0025) so the system uses the TP-Link
      SUBSYSTEM=="usb", ATTRS{idVendor}=="8087", ATTRS{idProduct}=="0025", ATTR{authorized}="0"
    '';
    fstrim.enable = true;
    printing.enable = true;
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    # OpenSSH is now managed via homelab.ssh
    # openssh.enable = true;

    qemuGuest.enable = true;

    displayManager.sddm.wayland.enable = lib.mkForce false;
    displayManager.autoLogin = {
      enable = true;
      user = "abl030";
    };

    xserver.displayManager.setupCommands = ''
      ${pkgs.xorg.xrandr}/bin/xrandr --auto
      ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-2 --mode 1920x1080 --rotate right --pos 0x0
      ${pkgs.xorg.xrandr}/bin/xrandr --output DP-3 --mode 2560x1440 --primary --pos 1080x0
      ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-3 --mode 1920x1080 --pos 3640x0
    '';
  };

  virtualisation.docker.enable = true;
  virtualisation.docker.liveRestore = false;

  time.timeZone = "Australia/Perth";
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_AU.UTF-8";
    LC_IDENTIFICATION = "en_AU.UTF-8";
    LC_MEASUREMENT = "en_AU.UTF-8";
    LC_MONETARY = "en_AU.UTF-8";
    LC_NAME = "en_AU.UTF-8";
    LC_NUMERIC = "en_AU.UTF-8";
    LC_PAPER = "en_AU.UTF-8";
    LC_TELEPHONE = "en_AU.UTF-8";
    LC_TIME = "en_AU.UTF-8";
  };

  systemd.services."gnome-remote-desktop".wantedBy = ["graphical.target"];
  security.rtkit.enable = true;

  users.users.abl030 = {
    isNormalUser = true;
    description = "Andy";
    extraGroups = ["networkmanager" "wheel" "libvirtd" "vboxusers" "docker"];
    shell = pkgs.zsh;
    packages = with pkgs; [];
  };

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    gnome-remote-desktop
    kdiskmark
  ];

  programs = {
    firefox.enable = true;
    zsh.enable = true;
  };

  system.stateVersion = "24.05";
  nix.settings.experimental-features = ["nix-command" "flakes"];
}
