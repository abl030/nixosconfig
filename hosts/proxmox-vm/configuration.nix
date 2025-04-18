{ config, pkgs, inputs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      # Our modulat tailscale setup that should work anywhere.
      ../services/tailscale/tailscale.nix
      # Our mounts
      ../services/mounts/nfs.nix
      # ../services/mounts/cifs.nix

      ../common/configuration.nix
    ];

  #enable docker
  virtualisation.docker.enable = true;
  # Docker fileSystems
  fileSystems."/mnt/docker" = # Choose your desired mount point inside the VM
    {
      device = "dockerVolumes"; # <-- Use the tag you set in Proxmox
      fsType = "virtiofs";
      options = [
        "defaults"
        # Potentially add UID/GID mapping options here if needed, e.g.:
        # "uid=1000"
        # "gid=100" # users group in NixOS often
      ];
    };
  fileSystems."/mnt/data2" = # Choose your desired mount point inside the VM
    {
      device = "data"; # <-- Use the tag you set in Proxmox
      fsType = "virtiofs";
      options = [
        "defaults"
        # Potentially add UID/GID mapping options here if needed, e.g.:
        # "uid=1000"
        # "gid=100" # users group in NixOS often
      ];
    };


  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Enable networking
  networking.networkmanager.enable = true;
  # Enable the qemu agent
  services.qemuGuest.enable = true;

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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abl030 = {
    isNormalUser = true;
    description = "Andy";
    extraGroups = [ "networkmanager" "wheel" "libvirtd" "vboxusers" "docker" ];
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
  ];

  programs.zsh.enable = true;

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  networking.firewall.enable = false;
  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [
  # ];
  # networking.firewall.allowedUDPPorts = [ ];
  #
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos"; # Match label during formatting
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT"; # Match label during formatting
    fsType = "vfat";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
