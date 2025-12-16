# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{pkgs, ...}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    # ../services/jellyfin/jellyfin.nix
    ../services/mounts/nfs_local.nix
    # We need fuse mounts for jellyfin inotify
    ../services/mounts/fuse.nix

    ../services/tailscale/tailscale.nix
    ../common/ssh.nix

    # Our docker services
    ../../docker/jellyfinn/docker-compose.nix
    ../../docker/management/igpu/docker_compose.nix
    ../../docker/plex/docker-compose.nix
    ../../docker/tdarr/igp/docker-compose.nix
  ];

  # Grouping all boot loader and kernel options under a single 'boot' attribute set.
  # This is standard practice for structuring NixOS configurations.
  boot = {
    # Use the systemd-boot EFI boot loader.
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    # Use latest kernel.
    kernelPackages = pkgs.linuxPackages_latest;

    # Increase inotify limits for large Jellyfin libraries
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = 2097152;
    };
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    nixCaches = {
      enable = true;
      profile = "internal"; # or "external"
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
    };
  };
  # Use Flakes
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
  };

  # Consolidating hardware settings into a single attribute set improves clarity.
  hardware = {
    # Igpu test
    graphics = {
      enable = true;
    };
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  virtualisation.docker.enable = true;

  networking.hostName = "igpu"; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abl030 = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = ["docker" "wheel" "video" "render"]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
      git
    ];
  };

  programs.zsh.enable = true;
  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    libva-utils
    radeontop
    nvtopPackages.amd
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:
  # Group all service definitions into a single block to avoid re-defining the `services` key.
  services = {
    qemuGuest.enable = true;
    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
      };
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?
}
