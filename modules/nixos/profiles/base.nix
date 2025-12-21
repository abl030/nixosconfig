# modules/nixos/profiles/base.nix
{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}: {
  # ---------------------------------------------------------
  # 0. IDENTITY
  # ---------------------------------------------------------
  networking.hostName = hostConfig.hostname;
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

    # Garbage Collection (Weekly)
    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "02:00";
      options = lib.mkDefault "--delete-older-than 3d";
    };
  };

  # ---------------------------------------------------------
  # 3. SHELL & ENVIRONMENT
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
  # 4. ADMIN USER
  # ---------------------------------------------------------
  # Dynamically configure the user defined in hosts.nix
  users.users.${hostConfig.user} = {
    isNormalUser = true;
    description = "Andy";
    shell = pkgs.zsh;

    # Core groups. Hosts can add more (e.g. docker) via extraGroups in their own config
    extraGroups = ["wheel" "networkmanager"];

    # Automatically pull authorized keys from hosts.nix
    openssh.authorizedKeys.keys = hostConfig.authorizedKeys or [];
  };
}
