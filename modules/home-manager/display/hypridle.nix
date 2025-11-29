{
  lib,
  config,
  pkgs,
  inputs, # <--- Add inputs here
  ...
}:
with lib; let
  cfg = config.homelab.hypridle;
in {
  options.homelab.hypridle = {
    enable = mkEnableOption "Enable Hypridle idle daemon";

    lockTimeout = mkOption {
      type = types.int;
      default = 300; # 5 Minutes
      description = "Seconds before screen locks";
    };

    suspendTimeout = mkOption {
      type = types.int;
      default = 900; # 15 Minutes
      description = "Seconds before system suspends";
    };
  };

  config = mkIf cfg.enable {
    # Use the flake package that matches your graphics drivers
    home.packages = [inputs.hypridle.packages.${pkgs.system}.hypridle];

    # IMPORTANT: Ensure Hyprland respects these apps when fullscreen
    wayland.windowManager.hyprland.settings.windowrulev2 = [
      "idleinhibit fullscreen, class:^(firefox)$"
      "idleinhibit fullscreen, class:^(mpv)$"
    ];

    xdg.configFile."hypr/hypridle.conf".text = ''
      general {
          # Avoid starting multiple hyprlock instances.
          lock_cmd = pidof hyprlock || hyprlock

          # Lock before suspend.
          before_sleep_cmd = loginctl lock-session

          # Turn on display after sleep.
          after_sleep_cmd = hyprctl dispatch dpms on

          # Required for Firefox/MPV to inhibit idle
          ignore_dbus_inhibit = false
      }

      # 1. Lock Screen (${toString cfg.lockTimeout}s)
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = loginctl lock-session
      }

      # 2. Screen Off (Lock time + 30s)
      listener {
          timeout = ${toString (cfg.lockTimeout + 30)}
          on-timeout = hyprctl dispatch dpms off
          on-resume = hyprctl dispatch dpms on
      }

      # 3. Suspend (${toString cfg.suspendTimeout}s)
      listener {
          timeout = ${toString cfg.suspendTimeout}
          on-timeout = systemctl suspend
      }
    '';
  };
}
