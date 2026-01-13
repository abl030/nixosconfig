# modules/nixos/profiles/base.nix
{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}: {
  # ---------------------------------------------------------
  # 0. IDENTITY & BOOTSTRAP
  # ---------------------------------------------------------
  networking.hostName = hostConfig.hostname;

  # Default Bootloader (Standard UEFI)
  # WSL and specialty hosts should override this to false
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # ---------------------------------------------------------
  # 1. LOCALES & TIME
  # ---------------------------------------------------------
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

  # ---------------------------------------------------------
  # 2. NIX SETTINGS
  # ---------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      download-buffer-size = 256 * 1024 * 1024; # 256 MB
      auto-optimise-store = true;
    };

    # Garbage Collection (Weekly fallback)
    # The homelab.update module below will take precedence if enabled
    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "02:00";
      options = lib.mkDefault "--delete-older-than 3d";
    };
  };

  # ---------------------------------------------------------
  # 3. CORE SERVICES & HARDWARE
  # ---------------------------------------------------------
  # Reasonable default for most servers/desktops (SSDs/VirtIO)
  services.fstrim.enable = lib.mkDefault true;

  # Standard Networking
  networking.networkmanager.enable = lib.mkDefault true;

  # ---------------------------------------------------------
  # 4. HOMELAB "BATTERIES INCLUDED" DEFAULTS
  # ---------------------------------------------------------
  # By using mkDefault, we ensure every new machine is manageable
  # immediately, but power users (Epi/Framework) can tune settings.

  homelab = {
    # 1. Access
    ssh = {
      enable = lib.mkDefault true;
      # Default to secure (keys only), override to false for debug/install
      secure = lib.mkDefault true;
    };

    tailscale = {
      enable = lib.mkDefault true;
      # Base server doesn't need TPM override usually, unless it's a VM hopping hosts
      tpmOverride = lib.mkDefault false;
    };

    # 2. Maintenance
    update = {
      enable = lib.mkDefault true;
      collectGarbage = lib.mkDefault true;
      trim = lib.mkDefault true;
      # Don't reboot by default, let specific servers opt-in
      rebootOnKernelUpdate = lib.mkDefault false;
    };

    # 3. Caching
    nixCaches = {
      enable = lib.mkDefault true;
      # "internal" is safe for everything inside the LAN
      profile = lib.mkDefault "internal";
    };
  };

  # ---------------------------------------------------------
  # 5. SHELL & ENVIRONMENT
  # ---------------------------------------------------------
  # Enforce Zsh for everything
  environment.pathsToLink = ["/share/zsh"];

  programs = {
    zsh.enable = true;
    bash.blesh.enable = true;
    nix-ld.enable = true;
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    home-manager
    killall
    parted
    nvd # For activation diffs
  ];

  # Pretty diffs on rebuild
  system.activationScripts.diff = ''
    if [[ -e /run/current-system ]]; then
      echo "--- diff to current-system"
      ${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff /run/current-system "$systemConfig"
      echo "---"
    fi
  '';

  # ---------------------------------------------------------
  # 6. ADMIN USER
  # ---------------------------------------------------------
  # Dynamically configure the user defined in hosts.nix
  users.users.${hostConfig.user} =
    {
      isNormalUser = true;
      description = "Andy";
      shell = pkgs.zsh;

      # Core groups. Hosts can add more (e.g. docker) via extraGroups in their own config
      extraGroups = ["wheel" "networkmanager"];

      # Automatically pull authorized keys from hosts.nix
      openssh.authorizedKeys.keys = hostConfig.authorizedKeys or [];
    }
    // lib.optionalAttrs (hostConfig ? initialHashedPassword) {
      # Optional per-host initial password hash (set in hosts.nix).
      # This allows initial access without passwordless sudo and won't
      # overwrite a password you've already changed on the host.
      inherit (hostConfig) initialHashedPassword;
    };

  # ---------------------------------------------------------
  # 7. SUDO POLICY
  # ---------------------------------------------------------
  # Allow per-host control for automation/test VMs via hosts.nix.
  security.sudo = {
    enable = lib.mkDefault true;
    wheelNeedsPassword = lib.mkDefault (!(hostConfig.sudoPasswordless or false));
  };
}
