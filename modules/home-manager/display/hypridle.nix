# modules/home-manager/display/hypridle.nix
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hypridle;

  # Create a dedicated script to handle the logging.
  # This guarantees the shell environment is correct and permissions are handled.
  debugScript = pkgs.writeShellScript "hyprlock-debug" ''
    # echo a timestamp so we know the script actually triggered
    echo "--- Triggered at $(date) ---" >> /tmp/hyprlock.log

    # Run hyprlock with no buffering, appending to the log
    ${pkgs.coreutils}/bin/stdbuf -o0 -e0 ${pkgs.hyprlock}/bin/hyprlock --verbose >> /tmp/hyprlock.log 2>&1
  '';
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
    # Use the standard package from nixpkgs
    home.packages = [pkgs.hypridle];

    # IMPORTANT: Ensure Hyprland respects these apps when fullscreen
    wayland.windowManager.hyprland.settings.windowrulev2 = [
      "idleinhibit fullscreen, class:^(firefox)$"
      "idleinhibit fullscreen, class:^(mpv)$"
    ];

    xdg.configFile."hypr/hypridle.conf".text = ''
      general {
          # We removed 'pidof hyprlock ||' to force the script to run every time
          # so we definitely get logs, even if a zombie process exists.
          lock_cmd = ${debugScript}

          # Lock before suspend.
          before_sleep_cmd = loginctl lock-session

          # Turn on display after sleep.
          after_sleep_cmd = hyprctl dispatch dpms on; wait 10; hyprctl keyword misc:allow_session_lock_restore 1; hyprctl dispatch exec hyprlock

          ignore_dbus_inhibit = false
      }

      # 1. Lock Screen (${toString cfg.lockTimeout}s)
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = ${debugScript}
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
