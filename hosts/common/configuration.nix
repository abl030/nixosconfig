# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, system, ... }:

{
  imports =
    [
      ./auto_update.nix
      ./printing.nix
      ./ssh.nix
    ];

  # add in nix-ld for non-nix binaries
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = [ ];

  # Optimise nix store to save space daily.
  nix.optimise.automatic = true;
  nix.optimise.dates = [ "03:45" ]; # Optional; allows customizing optimisation schedule

  # Automate garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
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
  environment.systemPackages = [
    pkgs.nerd-fonts.sauce-code-pro
    pkgs.nvd
    pkgs.xorg.xauth
  ];
  # need to run fc-cache -fv to update font fc-cache

  services.locate = {
    enable = true;
    interval = "hourly"; # Or whatever interval you prefer
    pruneFS = [
    ];
  };
}
