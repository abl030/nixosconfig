# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    # Our modulat tailscale setup that should work anywhere.
    ../services/tailscale/tailscale.nix
    # Our mounts
    ../services/mounts/nfs.nix
    # ../services/mounts/cifs.nix
    ../common/configuration.nix
    ../common/desktop.nix
    # Framework specific hardware-configuration
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    # Our sleep then hibernate script
    # https://gist.github.com/mattdenner/befcf099f5cfcc06ea04dcdd4969a221
    ../framework/sleep-then-hibernate.nix
    # ../framework/hibernate-fix.nix
    # ../framework/hibernatefix2.nix
    # Nosleep scripts
    ../services/system/ssh_nosleep.nix
    ../services/system/remote_desktop_nosleep.nix
  ];

  # Framework specific hardware-configuration
  services.fwupd.enable = true;
  services.fwupd.extraRemotes = ["lvfs-testing"];

  # # Make fingerprint reader work
  # services.fprintd.enable = true;
  #
  # Wifi fix
  hardware.wirelessRegulatoryDatabase = true;
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom="AU"
  '';

  # # we need fwupd 1.9.7 to downgrade the fingerprint sensor firmware
  # services.fwupd.package = (import
  #   (builtins.fetchTarball {
  #     url = "https://github.com/NixOS/nixpkgs/archive/bb2009ca185d97813e75736c2b8d1d8bb81bde05.tar.gz";
  #     sha256 = "sha256:003qcrsq5g5lggfrpq31gcvj82lb065xvr7bpfa8ddsw8x4dnysk";
  #   })
  #   {
  #     inherit (pkgs) system;
  #   }).fwupd;

  # Hardware acceleration for video
  hardware.graphics.enable = true;

  # lets use the latest kernel because we are stupid
  # boot.kernelPackages = pkgs.linuxPackages_latest;
  # For now we are using xanmod to limit us to 6.11.
  # This is because 6.12.x breaks hibernation
  # boot.kernelPackages = pkgs.linuxPackages_6_11;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxPackages_6_13;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "framework"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

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

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
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

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abl030 = {
    isNormalUser = true;
    description = "Andy";
    extraGroups = ["networkmanager" "wheel" "libvertd" "dialout"];
    shell = pkgs.zsh;
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
    gh
    git
    vim
    gnome-remote-desktop
    dmidecode
    fprintd
  ];
  programs.fish.enable = true;

  programs.zsh.enable = true;
  # programs.zsh.enable = true;
  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # # Hibernation
  # powerManagement.enable = true;
  # # boot.resumeDevice = "/dev/nvme0n1p3";
  # boot.initrd.systemd.enable = true;
  #
  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
}
