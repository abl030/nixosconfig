# modules/nixos/default.nix
{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./common
    ./nix_caches
    ./ci
    ./autoupdate
    ./services
    ./shell
  ];
}
