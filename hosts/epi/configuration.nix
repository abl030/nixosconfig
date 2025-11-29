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
    ../services/display/sunshine.nix
    ../services/display/gnome-remote-desktop.nix
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
    hyprland = {
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

  # Keep persistent logs just in case
  services.journald.extraConfig = "Storage=persistent";

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    # --- KERNEL PARAMS ---
    kernelParams = [
      # Intel Arc Requirements
      "i915.force_probe=56a6"
      # "i915.enable_guc=3" # DISABLED: Try booting without GuC first to rule it out for suspend

      # Suspend/Crash Fixes
      "pcie_aspm=off" # Disable PCIe Active State Power Management (Common cause of wake crashes)
      "nowatchdog" # Disable watchdog timers that might bite during wake
    ];

    # Blacklist modules known to crash on wake on AMD/Intel mix
    blacklistedKernelModules = [
      "sp5100_tco" # AMD Watchdog - notorious for wake crashes
      "iTCO_wdt" # Intel Watchdog
    ];

    initrd.kernelModules = ["i915"];
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
    fstrim.enable = true;
    printing.enable = true;
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    openssh.enable = true;
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
