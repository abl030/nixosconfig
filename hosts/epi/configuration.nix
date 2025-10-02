# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{pkgs, ...}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    # Our modulat tailscale setup that should work anywhere.
    ../services/tailscale/tailscale.nix
    # Our mounts
    ../services/mounts/nfs.nix
    # ../services/mounts/cifs.nix

    ../services/nvidia/intel.nix
    ../common/configuration.nix
    ../common/desktop.nix
    # sunshine
    ../services/display/sunshine.nix
    ## And allow gnome-remote-desktop for logged in users
    ../services/display/gnome-remote-desktop.nix
    # Lets try the bluetooth fix after suspend for buds 3 pro
    # ../framework/hibernatefix2.nix
    # Nosleep scripts
    ../services/system/remote_desktop_nosleep.nix

    ../../docker/management/epi_management/docker_compose.nix
    ../../docker/tdarr/epi/docker-compose.nix
  ];

  # Group all boot-related settings into a single block.
  boot = {
    # 2. Use the LATEST kernel for best Arc support
    kernelPackages = pkgs.linuxPackages_latest;
    # 3. Kernel parameters (you had these, keep them, especially enable_guc)
    kernelParams = [
      "i915.force_probe=56a6" # Good to have for DG2
      "i915.enable_guc=3" # Essential for enabling GuC & HuC
      # "loglevel=7"          # Optional: for more dmesg verbosity during boot
    ];
    # 5. Explicitly add i915 module to initrd to ensure it loads early with firmware
    initrd.kernelModules = ["i915"];
    kernelModules = ["i915"]; # Also for main system
    # Bootloader.
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  # Group all hardware settings into one block.
  hardware = {
    # 4. Enable redistributable firmware (this should pull in i915 firmware)
    enableRedistributableFirmware = true;
    # Enable bluetooth
    bluetooth.enable = true;
    # Logitech devices
    logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };
  };

  # Group all networking configurations to avoid repeated keys.
  networking = {
    hostName = "epimetheus"; # Define your hostname.
    networkmanager.enable = true;
    # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
    # networking.interfaces.enp9s0.wakeOnLan.enable = true;
    # Open ports in the firewall.
    firewall = {
      allowedTCPPorts = [
        3389
        3390
      ];
      allowedUDPPorts = [5140];
    };
  };

  # Group all service definitions into a single attribute set.
  services = {
    qemuGuest.enable = true;
    fstrim.enable = true;
    # Enable the X11 windowing system.
    xserver = {
      enable = true;
      # Configure keymap in X11
      xkb = {
        layout = "us";
        variant = "";
      };
    };
    # Enable the GNOME Desktop Environment.
    # Don't forget to enable the home manager options
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    # Enable CUPS to print documents.
    printing.enable = true;
    # Enable sound with pipewire.
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      # If you want to use JACK applications, uncomment this
      #jack.enable = true;

      # use the example session manager (no others are packaged yet so this is enabled by default,
      # no need to redefine it in your config for now)
      #media-session.enable = true;
    };
    # Enable the OpenSSH daemon.
    openssh.enable = true;
  };

  # lets use the latest kernel because we are stupid
  # boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxPackages_6_12;
  # boot.kernelModules = [ "uinput" ];

  #enable virtualbox
  # virtualisation.virtualbox.host.enable = true;
  # users.extraGroups.vboxusers.members = [ "user-with-access-to-virtualbox" ];
  # virtualisation.virtualbox.host.enableExtensionPack = true;
  # boot.kernelParams = [
  #   #This is to fix virtualbox in the 6.12 kernel
  #   "kvm.enable_virt_at_load=0"
  #   # This is to fix hanging on shutdown
  #   "reboot=acpi"
  # ];

  # Enable virt-manager
  # virtualisation.libvirtd.enable = true;
  # programs.virt-manager.enable = true;

  #enable docker
  virtualisation.docker.enable = true;
  virtualisation.docker.liveRestore = false;

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Set your time zone.
  time.timeZone = "Australia/Perth";

  # Select internationalisation properties.
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

  # services.xserver.displayManager.gdm.wayland = false;
  # Remote desktop
  # services.xrdp.enable = true;
  # services.xrdp.defaultWindowManager = "${pkgs.gnome-session}/bin/gnome-session";
  # services.xrdp.defaultWindowManager = "gnome-remote-desktop";
  # services.xrdp.openFirewall = true;
  systemd.services."gnome-remote-desktop".wantedBy = ["graphical.target"];
  # services.gnome.gnome-remote-desktop.enable = true;
  # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
  # If no user is logged in, the machine will power down after 20 minutes.
  # systemd.targets.sleep.enable = false;
  # systemd.targets.suspend.enable = false;
  # systemd.targets.hibernate.enable = false;
  # systemd.targets.hybrid-sleep.enable = false;
  #
  #This is LXQT - strangely suspend/resume works fine here?
  # services.xserver.displayManager.lightdm.enable = true;
  # services.xserver.desktopManager.lxqt.enable = true;

  # #KDE
  # Don't forget to enable the home manager options
  # services.displayManager.sddm.enable = true;
  # # services.desktopManager.plasma6.enable = true;
  # services.xserver.desktopManager.plasma5.enable = true;
  #
  # services.displayManager.defaultSession = "plasmax11";

  security.rtkit.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abl030 = {
    isNormalUser = true;
    description = "Andy";
    extraGroups = ["networkmanager" "wheel" "libvirtd" "vboxusers" "docker"];
    shell = pkgs.zsh;
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
    git
    vim
    gnome-remote-desktop
    kdiskmark
  ];

  # Group program enables into a single block.
  programs = {
    # Install firefox.
    firefox.enable = true;
    # programs.fish.enable = true;
    zsh.enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
  nix.settings.experimental-features = ["nix-command" "flakes"];
  # nix = {
  #   package = pkgs.nixFlakes;
  #   extraOptions = ''
  #     experimental-features = nix-command flakes
  #   '';
  # };
}
