# /etc/nixos/configuration.nix
{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    # package = pkgs.vscodium; # If using VSCodium

    profiles.default.extensions = with pkgs.vscode-extensions; [
      # Example extensions:
      rust-lang.rust-analyzer # Rust Analyzer
      bbenoist.nix # Nix language support
      jnoortheen.nix-ide # Another Nix IDE option
    ];
    # You can also enable user-scoped settings declaratively
    profiles.default.userSettings = {
      "nix.formatterPath" = "${pkgs.nixpkgs-fmt}/bin/nixd"; # Example for nix formatter
    };
  };
}
