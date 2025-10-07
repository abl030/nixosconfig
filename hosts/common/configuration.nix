# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./auto_update.nix
    ./printing.nix
    ./ssh.nix
  ];

  # for Zsh autocompletion
  environment.pathsToLink = ["/share/zsh"];

  # add in nix-ld for non-nix binaries
  # Group related settings under a single attribute set to avoid re-defining it.
  programs = {
    nix-ld = {
      enable = true;
      libraries = [];
    };
    bash.blesh.enable = true;
  };

  # sudo-rs
  # security.sudo-rs.enable = true;

  # swap caps lock to control, and right ctrl to caps lock.
  services.keyd = {
    enable = true;
    keyboards = {
      # "default" is a special name that keyd can use to apply to all keyboards
      # not explicitly configured, or you can try to find a more specific name
      # for your keyboard using `sudo keyd -l` and use that name here.
      # For most single-keyboard setups, "default" or using "*" for ids is fine.
      default = {
        # The 'ids' option specifies which devices this configuration applies to.
        # Using "*" applies it to all detected keyboards.
        # Alternatively, you can get specific vendor:product IDs using `sudo keyd -l`
        # e.g., ids = [ "046d:c077" ]; # Example for a Logitech mouse (not a keyboard, just for ID format)
        ids = ["*"];

        # The 'settings' attribute set maps directly to the keyd configuration file format.
        settings = {
          # The [main] layer is the default layer.
          main = {
            # Physical CapsLock becomes LeftControl
            capslock = "leftcontrol";

            # Physical RightControl becomes CapsLock
            rightcontrol = "capslock";
          };

          # You could define other layers here if needed, e.g.:
          # mylayer = {
          #   a = "b";
          # };
        };
      };
    };
  };

  # Group all nix-related options into a single attribute set.
  nix = {
    # Optimise nix store to save space daily.
    optimise = {
      automatic = true;
      dates = ["03:45"]; # Optional; allows customizing optimisation schedule
    };

    # Automate garbage collection
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    # Make our download buffer size bigger. Gigabit.
    settings = {
      # Increase the download buffer to 128 MiB to prevent stalls
      download-buffer-size = 256 * 1024 * 1024;
    };
  };

  # Pretty diffs for packages on rebuild
  system.activationScripts.diff = ''
    if [[ -e /run/current-system ]]; then
    echo "--- diff to current-system"
    ${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff /run/current-system "$systemConfig"
    echo "---"
    fi
  '';

  # install nerdfonts
  # and common packages
  environment.systemPackages = [
    pkgs.nerd-fonts.sauce-code-pro
    pkgs.nvd
    pkgs.xorg.xauth
    pkgs.home-manager
    pkgs.parted
  ];
  # need to run fc-cache -fv to update font fc-cache

  # services.locate = {
  #   enable = true;
  #   interval = "hourly"; # Or whatever interval you prefer
  #   pruneFS = [
  #   ];
  # };
}
