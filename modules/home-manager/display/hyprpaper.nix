{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprpaper;
  wallPath = builtins.toString (builtins.path {
    path = cfg.wallpaper;
    name = "wallpaper";
  });
in {
  options.homelab.hyprpaper = {
    enable = mkEnableOption "Enable Hyprpaper wallpaper engine";
    wallpaper = mkOption {
      type = types.path;
      default = pkgs.runCommand "fallback-wall.png" {} ''
        ${pkgs.imagemagick}/bin/convert -size 1920x1080 xc:#2C2A24 png:$out
      '';
      description = "Path to the wallpaper image";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [pkgs.hyprpaper];

    xdg.configFile."hypr/hyprpaper.conf".text = ''
      ipc = on
      splash = false

      # v0.8.0 requires preloading before assignment
      preload = ${wallPath}

      # Use the new block syntax for the fallback/wildcard
      wallpaper {
          monitor =
          path = ${wallPath}
          # fit_mode = cover (optional: cover | contain | tile | fill)
      }
    '';
  };
}
