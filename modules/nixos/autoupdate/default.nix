# modules/nixos/default.nix
{...}: {
  imports = [
    ./update.nix
    ./verify.nix
    ./push-deploy.nix
  ];
}
