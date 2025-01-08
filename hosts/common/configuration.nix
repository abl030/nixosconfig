# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, ... }:

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

  system.activationScripts.diff = ''
    if [[ -e /run/current-system ]]; then
      ${pkgs.nix}/bin/nix store diff-closures /run/current-system "$systemConfig"
    fi
  '';

  # install nerdfonts
  environment.systemPackages = [
    pkgs.nerd-fonts.sauce-code-pro
  ];
  # need to run fc-cache -fv to update font fc-cache
}
