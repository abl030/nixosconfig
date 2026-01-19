{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./tailscale # Auto-resolves to ./tailscale/default.nix
    ./ssh # Auto-resolves to ./ssh/default.nix
    ./mounts # Auto-resolves to ./mounts/default.nix
    ./display/hyprland.nix
    ./display/wayvnc.nix
    ./system/storage.nix
    ./display/sunshine.nix
    ./nginx.nix
  ];
}
