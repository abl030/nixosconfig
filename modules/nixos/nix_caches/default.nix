# modules/nixos/default.nix
{...}: {
  imports = [
    ./nginx_nix_mirror.nix
    ./client_profile.nix
  ];
}
