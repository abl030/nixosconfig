# modules/nixos/default.nix
{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./github-runner.nix
  ];
}
