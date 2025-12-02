{lib, ...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ../../modules/home-manager/multimedia/spicetify.nix
    ../../modules/home-manager/display/rofi.nix # <-- Import new module
    ./epi_home_specific.nix
  ];

  homelab = {
    hyprland = {
      enable = true;
    };
    spicetify = {
      enable = true;
    };
    rofi = {
      enable = true; # <-- Enable Rofi
    };
    hypridle = {
      enable = true;
      lockTimeout = 300;
      suspendTimeout = 900;
      # debug = true;
    };
    vnc = {
      enable = true;
      secure = true;
      output = "HDMI-A-3";
    };
  };

  # --- Monitor Config (Left -> Middle -> Right) ---
  wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    # 1. Left: Acer (Portrait)
    "HDMI-A-2, 1920x1080@75, 0x0, 1, transform, 3"

    # 2. Middle: Philips 32" (1440p @ 144Hz)
    "DP-3, 2560x1440@144, 1080x0, 1"

    # 3. Right: Philips 24" (1080p)
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
