# modules/nixos/default.nix
{...}: {
  imports = [
    ./github-runner.nix
    ./rolling-flake-update.nix
  ];
}
