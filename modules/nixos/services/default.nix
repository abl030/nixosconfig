# modules/nixos/default.nix
{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./tailscale.nix
    ./display/hyprland.nix
    ./display/wayvnc.nix
    ./system/storage.nix
    ./display/sunshine.nix
  ];
}
