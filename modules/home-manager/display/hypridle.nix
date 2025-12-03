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

  # 4. Suspend Loop Script (Generic Retry Logic)
  #    Attempts to suspend. If systemctl fails (due to inhibitors), it waits
  #    the full timeout duration again before retrying.
  suspendScript = pkgs.writeShellScript "hypridle-suspend-loop" ''
    TIMEOUT=${toString cfg.suspendTimeout}

    while true; do
      if systemctl suspend; then
        # If suspend succeeds, the system sleeps. The script pauses here.
        # When woken, 'on-resume' (below) kills this script.
        # If we somehow get here without being killed, exit cleanly.
        exit 0
      else
        # If suspend failed (inhibited), wait and retry.
        echo "Suspend failed/inhibited. Retrying in $TIMEOUT seconds..."
        sleep $TIMEOUT
      fi
    done
  '';
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
    # Added brightnessctl for dimming, procps for pkill in on-resume
    home.packages = [
      pkgs.hypridle
      pkgs.brightnessctl
      pkgs.procps
    ];

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
          after_sleep_cmd = hyprctl dispatch dpms on

          ignore_dbus_inhibit = false
      }

      # 1. Lock Screen (${toString cfg.lockTimeout}s)
      listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = ${finalLockCmd}
      }

      # 2. Dim Screen (Lock time - 30s)
      # Replaced DPMS off (which was causing crashes) with a brightness warning.
      # This dims the screen to 10% to suggest we are going idle.
      listener {
          timeout = ${toString (cfg.lockTimeout - 30)}
          on-timeout = ${pkgs.brightnessctl}/bin/brightnessctl -s set 10%
          on-resume = ${pkgs.brightnessctl}/bin/brightnessctl -r
      }

      # 3. Suspend (${toString cfg.suspendTimeout}s)
      # Executes the loop script. If blocked by inhibitors, it retries every ${toString cfg.suspendTimeout}s.
      # We kill the script on resume so it doesn't loop forever after wake.
      listener {
          timeout = ${toString cfg.suspendTimeout}
          on-timeout = ${suspendScript}
          on-resume = ${pkgs.procps}/bin/pkill -f hypridle-suspend-loop
      }
    '';
  };
}
