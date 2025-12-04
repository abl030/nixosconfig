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
    # ../services/display/sunshine.nix
    # ../services/display/gnome-remote-desktop.nix
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

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    # --- KERNEL PARAMS ---
    kernelParams = [
      # Intel Arc Requirements
      # "i915.force_probe=56a6"
      # "i915.force_probe=!56a6"
      # "i915.enable_guc=3" # DISABLED: Try booting without GuC first to rule it out for suspend
      "xe.force_probe=56a6"
      # "mem_sleep_default=s2idle"

      "pcie_aspm=off"
      # NEW: Fix for PNP0C02 / device:0f crash
      # This tells the kernel not to use the ACPI resource conflict check for the SMBus/Backlight
      "acpi_enforce_resources=lax"

      # NEW: Stop PCI errors from panicking the kernel
      "pci=noaer"

      # CRITICAL MISSING FIX: Prevent Micron P3 NVMe from sleeping too deeply.
      # This prevents the hard freeze (fans spinning) on wake.
      "nvme_core.default_ps_max_latency_us=0"
      # Helps prevent the IOMMU from blocking device wake-up on Ryzen.
      "iommu=pt"
      # "nowatchdog" # Disable watchdog timers that might bite during wake
      "video=HDMI-A-2:1920x1080@75e"
      "video=DP-3:2560x1440@144e"
      "video=HDMI-A-3:1920x1080@60e"
    ];

    # Blacklist modules known to crash on wake on AMD/Intel mix
    blacklistedKernelModules = [
      "i915"
      "sp5100_tco" # THE PRIME SUSPECT: AMD Watchdog Timer (Part of PNP0C02)
      "ccp" # AMD Cryptographic Coprocessor (The device at 0f:00.1)
      "i2c_piix4" # AMD SMBus driver (Often conflicts with PNP0C02)
      # "xe"
      # "sp5100_tco" # AMD Watchdog - notorious for wake crashes
      # "iTCO_wdt" # Intel Watchdog
    ];

    initrd.kernelModules = [
      "xe"
      # "i915"
    ];
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  powerManagement = {
    enable = true;
    powerDownCommands = ''
      # FUNCTION: Unbind a device if it exists
      unbind_dev() {
        if [ -e "/sys/bus/pci/devices/$1/driver/unbind" ]; then
          echo -n "$1" > "/sys/bus/pci/devices/$1/driver/unbind"
        fi
      }

      # 1. The Noisy Chipset USB (02:00.0)
      unbind_dev "0000:02:00.0"

      # 2. THE SILENT KILLER: CPU USB Controller (0f:00.3)
      # This lives on the bus identified by your pm_trace
      unbind_dev "0000:0f:00.3"

      # 3. Audio Controllers (Common cause of hangs)
      # AMD Motherboard Audio (0f:00.4)
      unbind_dev "0000:0f:00.4"
      # Intel Arc Audio (0d:00.0)
      unbind_dev "0000:0d:00.0"

      # 4. WiFi (Optional, but safer to kill)
      unbind_dev "0000:07:00.0"

      sleep 1
    '';

    resumeCommands = ''
      # Rebind everything.
      # We use '|| true' so the script continues even if one fails.

      # USB Controllers
      echo -n "0000:02:00.0" > /sys/bus/pci/drivers/xhci_hcd/bind || true
      echo -n "0000:0f:00.3" > /sys/bus/pci/drivers/xhci_hcd/bind || true

      # Audio Controllers
      echo -n "0000:0f:00.4" > /sys/bus/pci/drivers/snd_hda_intel/bind || true
      echo -n "0000:0d:00.0" > /sys/bus/pci/drivers/snd_hda_intel/bind || true

      # WiFi
      echo -n "0000:07:00.0" > /sys/bus/pci/drivers/iwlwifi/bind || true
    '';
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
