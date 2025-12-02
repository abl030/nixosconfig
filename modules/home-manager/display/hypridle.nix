# modules/home-manager/display/hypridle.nix
#
# DEBUGGING HYPRLOCK CRASHES:
# If hyprlock starts crashing, set `homelab.hypridle.debug = true;` in your home.nix.
#
# This will stream logs to /tmp/hyprlock.log.
# NOTE: The script below automatically filters out high-volume "polling" noise
# (timer threads, surface configuration, poll events) so the file remains readable.
#
# To watch the logs in real-time:
#   tail -f /tmp/hyprlock.log
#
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hypridle;

  # 1. The Debug Script (Aggressive logging, filtered, no buffering)
  # Only used if cfg.debug is true
  debugScript = pkgs.writeShellScript "hyprlock-debug" ''
    echo "--- Triggered at $(date) ---" >> /tmp/hyprlock.log

    # We pipe hyprlock output to grep to filter noise before writing to disk.
    # --line-buffered ensures we don't lose the last line (the crash) in a buffer.
    # Added "got poll event" to the exclusion list.
    ${pkgs.coreutils}/bin/stdbuf -o0 -e0 ${pkgs.hyprlock}/bin/hyprlock --verbose 2>&1 \
      | ${pkgs.gnugrep}/bin/grep --line-buffered -vE "timer thread firing|output .* done|configure with serial|Configuring surface|got poll event" \
      >> /tmp/hyprlock.log
  '';

  # 2. The Standard Command (Clean, checks for existing instances)
  standardCmd = "pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";

  # 3. Logic to switch between them
  lockCmd =
    if cfg.debug
    then debugScript
    else standardCmd;
in {
  options.homelab.hypridle = {
    enable = mkEnableOption "Enable Hypridle idle daemon";
    debug = mkEnableOption "Enable verbose logging to /tmp/hyprlock.log for crash diagnostics";

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
          # Dynamically chosen command based on the 'debug' option
          lock_cmd = ${lockCmd}

          # Lock before suspend.
          before_sleep_cmd = loginctl lock-session

          # Turn on display after sleep.
          after_sleep_cmd = hyprctl dispatch dpms on; wait 10; hyprctl keyword misc:allow_session_lock_restore 1; hyprctl dispatch exec hyprlock

          # Required for Firefox/MPV to inhibit idle
          ignore_dbus_inhibit = false
      }

      # 1. Lock Screen (${toString cfg.lockTimeout}s)
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = ${lockCmd}
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
