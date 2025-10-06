# modules/nixos/default.nix
{...}: {
  imports = [
    ./nginx_nix_mirror.nix
  ];
}
