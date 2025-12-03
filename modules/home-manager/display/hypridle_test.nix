# modules/home-manager/display/hypridle.nix
/*
===================================================================================
HYPRIDLE TEST MODULE - DPMS ONLY
===================================================================================

This is a stripped-down version of the module designed for debugging crashes.
It performs NO locking and NO suspending.

LOGIC:
1. Wait for 'lockTimeout' seconds.
2. Turn screens OFF (hyprctl dispatch dpms off).
3. Turn screens ON immediately when mouse moves (hyprctl dispatch dpms on).

===================================================================================
*/
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hypridle;
in {
  # ---------------------------------------------------------------------------
  # OPTIONS (Kept identical to original to preserve flake structure/inputs)
  # ---------------------------------------------------------------------------
  options.homelab.hypridle = {
    enable = mkEnableOption "Enable Hypridle idle daemon";

    # Kept for compatibility, but unused in this test module
    debug = mkEnableOption "Enable debug logging for Hyprlock (writes to /tmp/hyprlock.log)";

    lockTimeout = mkOption {
      type = types.int;
      default = 300; # 5 Minutes
      description = "Seconds before screen turns off (Test Mode)";
    };

    # Kept for compatibility, but unused in this test module
    suspendTimeout = mkOption {
      type = types.int;
      default = 900; # 15 Minutes
      description = "Seconds before system suspends";
    };
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    # Only hypridle is needed for this test.
    home.packages = [pkgs.hypridle];

    # Keep inhibitors so you can test if Firefox/MPV correctly stops the screen off
    # wayland.windowManager.hyprland.settings.windowrulev2 = [
    # "idleinhibit fullscreen, class:^(firefox)$"
    # "idleinhibit fullscreen, class:^(mpv)$"
    # ];

    xdg.configFile."hypr/hypridle.conf".text = ''
      general {
          # Ensure screen turns on if the system wakes up from a manual sleep
          after_sleep_cmd = hyprctl dispatch dpms on

          # Allow apps to stop the screen turning off
          ignore_dbus_inhibit = false
      }

      # TEST LISTENER: DPMS TOGGLE ONLY
      # Uses the 'lockTimeout' value to trigger screen off.
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = hyprctl dispatch dpms off
          on-resume = hyprctl dispatch dpms on
      }
    '';
  };
}
