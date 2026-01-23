{...}: {
  # Homelab infrastructure modules
  imports = [
    ./containers # Auto-resolves to ./containers/default.nix
    ./containers/stacks.nix
  ];
}
