{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprpaper;
in {
  options.homelab.hyprpaper = {
    enable = mkEnableOption "Enable Hyprpaper wallpaper engine";

    # Simple option to set one wallpaper for all screens
    wallpaper = mkOption {
      type = types.path;
      # Added .png extension to name and png: prefix to command to fix build error
      default = pkgs.runCommand "fallback-wall.png" {} ''
        ${pkgs.imagemagick}/bin/convert -size 1920x1080 xc:#2C2A24 png:$out
      '';
      description = "Path to the wallpaper image";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [pkgs.hyprpaper];

    xdg.configFile."hypr/hyprpaper.conf".text = ''
      preload = ${cfg.wallpaper}
      wallpaper = ,${cfg.wallpaper}
      splash = false
    '';
  };
}
