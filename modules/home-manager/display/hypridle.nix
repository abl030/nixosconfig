# modules/home-manager/display/hypridle.nix
/*
===================================================================================
HYPRIDLE DEBUGGING & CRASH LOGGING
===================================================================================

We have implemented a robust debug mode for Hyprlock. When enabled, instead of
running the binary directly, Hypridle executes a wrapper script that:
1. Unbuffers output (stdbuf) so logs are written instantly before a crash.
2. Redirects stderr to stdout.
3. Filters out high-frequency noise ("poll event", "frame") using grep.
4. Appends the clean logs to /tmp/hyprlock.log.

HOW TO ENABLE:
In your home configuration (e.g., home.nix), set:
    homelab.hypridle = {
      enable = true;
      debug = true;  <-- Enable this
    };

HOW TO VIEW LOGS:
Run this command to see the last 50 lines of the crash log:

    tail -n 50 /tmp/hyprlock.log

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

  # 1. The Debug Script (Filtered Logging)
  debugScript = pkgs.writeShellScript "hyprlock-debug" ''
    echo "--- Triggered at $(date) ---" >> /tmp/hyprlock.log
    ${pkgs.coreutils}/bin/stdbuf -o0 -e0 ${pkgs.hyprlock}/bin/hyprlock --verbose 2>&1 \
      | ${pkgs.gnugrep}/bin/grep --line-buffered -vE "poll event|frame" >> /tmp/hyprlock.log
  '';

  # 2. Logic to select the command based on the debug flag
  #    - Debug: Run the script (always)
  #    - Standard: Check for existing instance, then run raw binary
  finalLockCmd =
    if cfg.debug
    then "${debugScript}"
    else "pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";

  # 3. Logic for the "Restore" command (used in after_sleep_cmd)
  #    We want to use the debug script there too if debugging is on.
  finalRestoreCmd =
    if cfg.debug
    then "${debugScript}"
    else "${pkgs.hyprlock}/bin/hyprlock";
in {
  options.homelab.hypridle = {
    enable = mkEnableOption "Enable Hypridle idle daemon";

    debug = mkEnableOption "Enable debug logging for Hyprlock (writes to /tmp/hyprlock.log)";

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
          # Use our dynamic command
          lock_cmd = ${finalLockCmd}

          # Lock before suspend.
          before_sleep_cmd = loginctl lock-session

          # Turn on display after sleep.
          # Workaround: Run user-provided recovery commands for hyprlock crashes on resume
          after_sleep_cmd = hyprctl dispatch dpms on; wait 10; hyprctl keyword misc:allow_session_lock_restore 1; hyprctl dispatch exec ${finalRestoreCmd}

          ignore_dbus_inhibit = false
      }

      # 1. Lock Screen (${toString cfg.lockTimeout}s)
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = ${finalLockCmd}
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
