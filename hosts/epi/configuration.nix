{pkgs, ...}: {
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
  # This creates a second boot entry. Use this when booting as a VM.
  specialisation = {
    vm.configuration = {
      system.nixos.tags = ["vm"];

      # Force QEMU Guest Agent inside the VM
      services.qemuGuest.enable = true;

      # In VM mode, we might want to ensure PCI passthrough drivers are happy
      # But generally, the main config handles the Arc GPU.
      # If you need specific VM-only kernel params, add them here:
      # boot.kernelParams = [ "example_param_for_vm" ];
    };
  };

  homelab = {
    hyprland = {
      enable = true;
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
      collectGarbage = true;
      trim = true;
    };
  };

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    # Essential for Arc A310
    kernelParams = [
      "i915.force_probe=56a6"
      "i915.enable_guc=3"
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
      # enable32Bit = true; # (Uncomment if needed, 'hardware.opengl' is deprecated in newer nixpkgs for 'hardware.graphics')
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
    # xserver = {
    #   enable = true;
    #   xkb.layout = "us";
    # };
    # displayManager.gdm.enable = true;
    # desktopManager.gnome.enable = true;
    printing.enable = true;
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    openssh.enable = true;
    # The agent is enabled in the specialisation, but safe to leave here too
    qemuGuest.enable = true;
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
