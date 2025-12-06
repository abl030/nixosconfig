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
      kdePackages.kio-extras # Critical for protocols (sftp/smb) and thumbnails
      kdePackages.kio-admin

      # Thumbnails & Support
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.qtimageformats # WebP, TIFF, etc.
      kdePackages.qtsvg
      shared-mime-info # Helps identify file types

      # System Integration (Hyprland/Qt6)
      kdePackages.qtwayland
      kdePackages.qt6ct # Qt6 theming tool (Dolphin is Qt6)
    ];

    # Critical: Tells Dolphin to look in the Home Manager profile for the thumbnail plugins
    home.sessionVariables = {
      QT_PLUGIN_PATH = "${config.home.profileDirectory}/lib/qt-6/plugins:$QT_PLUGIN_PATH";
    };
  };
}
