# modules/nixos/default.nix
{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./nix_caches
    ./ci
  ];
}
