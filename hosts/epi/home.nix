{lib, ...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ./epi_home_specific.nix
  ];

  homelab.hyprland = {
    enable = true;
    vnc = true; # <--- Add this
  };

  # --- Monitor Config (Left -> Middle -> Right) ---
  wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    # 1. Left: Acer (Portrait)
    # 1080px wide after rotation
    "HDMI-A-2, 1920x1080@75, 0x0, 1, transform, 3"

    # 2. Middle: Philips 32" (1440p @ 144Hz)
    # Starts at 1080px (right after the portrait monitor)
    "DP-3, 2560x1440@144, 1080x0, 1"

    # 3. Right: Philips 24" (1080p)
    # Starts at 1080 + 2560 = 3640px
    "HDMI-A-3, 1920x1080@60, 3640x0, 1"

    # Fallback for anything else
    ", preferred, auto, 1"
  ];

  # Optional: Assign Workspaces to screens intuitively
  wayland.windowManager.hyprland.settings.workspace = [
    "1, monitor:HDMI-A-2" # Left
    "2, monitor:DP-3" # Middle
    "3, monitor:HDMI-A-3" # Right
  ];
}
