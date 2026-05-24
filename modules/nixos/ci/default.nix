# modules/nixos/default.nix
{...}: {
  imports = [
    ./rolling-flake-update.nix
  ];
}
