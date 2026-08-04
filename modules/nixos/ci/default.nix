# modules/nixos/default.nix
{...}: {
  imports = [
    ./cratedigger-12h-report.nix
    ./cratedigger-daily-checks.nix
    ./rolling-flake-update.nix
  ];
}
