{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ../../modules/home-manager/multimedia/spicetify.nix
    # ../../modules/home-manager/display/rofi.nix # Hyprland launcher
    ./epi_home_specific.nix
  ];

  # Persist GNOME monitor layout so it survives rebuilds/DE swaps
  xdg.configFile."monitors.xml".source = ./monitors.xml;

  homelab = {
    # --- Hyprland config (disabled, kept for easy swap-back) ---
    # remote-desktop = {
    #   enable = true;
    #   settings = {
    #     workspaces = [1 2 3 4];
    #     physicalMonitors = ["HDMI-A-2" "DP-3" "HDMI-A-3"];
    #     primaryMonitor = "DP-3";
    #     workspaceMaps = {
    #       "1" = "HDMI-A-2";
    #       "2" = "DP-3";
    #       "3" = "HDMI-A-3";
    #     };
    #     restoreCommands = ''
    #       hyprctl keyword monitor HDMI-A-2,1920x1080@75,0x0,1,transform,3
    #       hyprctl keyword monitor DP-3,2560x1440@144,1080x0,1
    #       hyprctl keyword monitor HDMI-A-3,1920x1080@60,3640x0,1
    #     '';
    #   };
    # };
    # hyprpaper = {
    #   enable = true;
    #   wallpaper = ../../modules/home-manager/display/back.jpg;
    # };
    spicetify = {
      enable = true;
    };
    # rofi = {
    #   enable = true;
    # };
    # hypridle = {
    #   enable = true;
    #   lockTimeout = 300;
    #   suspendTimeout = 900;
    # };
    # vnc = {
    #   enable = true;
    #   secure = true;
    #   output = "HDMI-A-3";
    # };
  };

  # --- Hyprland monitor config (disabled, kept for swap-back) ---
  # wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
  #   "HDMI-A-2, 1920x1080@75, 0x0, 1, transform, 3"
  #   "DP-3, 2560x1440@144, 1080x0, 1"
  #   "HDMI-A-3, 1920x1080@60, 3640x0, 1"
  #   ", preferred, auto, 1"
  # ];
  # wayland.windowManager.hyprland.settings.workspace = [
  #   "1, monitor:HDMI-A-2"
  #   "2, monitor:DP-3"
  #   "3, monitor:HDMI-A-3"
  # ];
}
