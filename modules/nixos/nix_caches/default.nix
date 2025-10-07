# modules/nixos/default.nix
{...}: {
  imports = [
    ./nix_cache.nix
    ./client_profile.nix
  ];
}
