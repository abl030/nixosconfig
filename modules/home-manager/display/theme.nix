{
  lib,
  config,
  ...
}:
with lib; {
  options.homelab.theme = {
    colors = {
      # Base Logic
      background = mkOption {
        type = types.str;
        default = "#2C2A24";
        description = "Main background color";
      };
      backgroundAlt = mkOption {
        type = types.str;
        default = "#3A372F";
        description = "Secondary/Card background color";
      };
      foreground = mkOption {
        type = types.str;
        default = "#DDD5C4";
        description = "Main text color";
      };

      # UI Elements
      border = mkOption {
        type = types.str;
        default = "#A0907A";
        description = "Inactive borders";
      };
      primary = mkOption {
        type = types.str;
        default = "#D08B57";
        description = "Primary focus/accent color (Orange)";
      };
      secondary = mkOption {
        type = types.str;
        default = "#BFAA80";
        description = "Secondary accent (Beige)";
      };

      # Status Colors (Mapped to Waybar accents)
      info = mkOption {
        type = types.str;
        default = "#7699A3";
        description = "Info/Blue";
      };
      success = mkOption {
        type = types.str;
        default = "#78997A";
        description = "Success/Green";
      };
      warning = mkOption {
        type = types.str;
        default = "#8D7AAE";
        description = "Warning/Purple";
      };
      urgent = mkOption {
        type = types.str;
        default = "#B05A5A";
        description = "Urgent/Red";
      };
    };
  };
}
