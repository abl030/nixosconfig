# modules/nixos/default.nix
{...}: {
  imports = [
    ./cratedigger-daily-checks.nix
    ./rolling-flake-update.nix
  ];
}
