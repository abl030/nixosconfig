# modules/nixos/default.nix
{...}: {
  imports = [
    ./update.nix
    ./verify.nix
  ];
}
