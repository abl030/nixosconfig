{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;
in {
  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager (with thumbnailers & Wayland support)";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Core
      kdePackages.dolphin
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kio-admin

      # Thumbnails & Support
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.qtimageformats
      kdePackages.qtsvg
      shared-mime-info

      # System Integration (Hyprland/Qt6)
      kdePackages.qtwayland
      kdePackages.qt6ct

      # Theming Packages (Required for Dark Mode)
      kdePackages.breeze # The Breeze Style
      kdePackages.breeze-icons # The Breeze Icons
    ];

    home.sessionVariables = {
      # 2. THE FIX: Explicitly inject the Store Paths for qt6ct and breeze into the plugin path.
      #    This guarantees Dolphin finds libqt6ct.so and Breeze styles without relying on profile symlinks.
      QT_PLUGIN_PATH = "${pkgs.kdePackages.qt6ct}/lib/qt-6/plugins:${pkgs.kdePackages.breeze}/lib/qt-6/plugins:${config.home.profileDirectory}/lib/qt-6/plugins";
      # Tells Dolphin to use qt6ct for configuration
      QT_QPA_PLATFORMTHEME = "qt6ct";
    };
  };
}
