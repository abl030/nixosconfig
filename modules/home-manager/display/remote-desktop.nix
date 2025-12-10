/*
===================================================================================
HYPRLAND HEADLESS REMOTE DESKTOP MODULE
===================================================================================

PURPOSE:
  Enables a "Game Console" like experience where the host machine switches to a
  virtual headless monitor for streaming, turning off physical screens for privacy
  and resource management.

USAGE (Host Configuration):
  Import this module and configure it in your host's 'home.nix':

  homelab.remote-desktop = {
    enable = true;
    settings = {
      # Workspaces to migrate to the headless session
      workspaces = [ 1 2 3 4 ];

      # List of physical monitors to DISABLE (Crucial for Sunshine capture)
      physicalMonitors = [ "HDMI-A-1" "DP-1" ];

      # Monitor to move windows back to when returning home
      primaryMonitor = "DP-1";

      # Commands to restore physical monitor layout (copy from hyprland.conf)
      restoreCommands = ''
        hyprctl keyword monitor DP-1,2560x1440@144,0x0,1
        hyprctl keyword monitor HDMI-A-1,1920x1080@60,2560x0,1
      '';
    };
  };

CLI COMMANDS:
  - Enter Remote Mode:  `remote-mode [1080p|1440p|4k]`
  - Return to Local:    `local-mode` (or press Super+Shift+D locally)

DESIGN DECISIONS & LEARNINGS:
  1. WHY DISABLE MONITORS?
     Simply using `dpms off` is insufficient. Sunshine's KMS capture prefers
     physical connectors even if they are "off", resulting in a black screen stream.
     We must use `hyprctl keyword monitor <name>,disable` to structurally remove
     them from the compositor, forcing Sunshine to fallback to the Headless output.

  2. SUNSHINE CONFIGURATION:
     Sunshine doesn't automatically detect new virtual outputs added at runtime.
     We must:
     a) Restart Sunshine after creating the output.
     b) Dynamically inject `output_name = <ID>` into ~/.config/sunshine/sunshine.conf.
     c) Ensure Sunshine is running with `capture = "wlr"` (wlroots) backend.

  3. VNC HANDLING:
     WayVNC binds to a specific output. When we disable physical monitors, the
     old VNC instance breaks. We actively `pkill` it and launch a new instance
     bound explicitly to `HEADLESS-2`.

  4. OVERLAP PREVENTION:
     We create `HEADLESS-2` at position `20000x0`. If created at `0x0`, it might
     briefly overlap with an existing monitor before disable commands run, causing
     Hyprland errors.

  5. SSH COMPATIBILITY:
     SSH sessions do not have `$HYPRLAND_INSTANCE_SIGNATURE` set. The scripts
     manually detect the active socket in `$XDG_RUNTIME_DIR/hypr` to allow
     remote execution.

===================================================================================
*/
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.remote-desktop;

  # Internal Constants
  headlessName = "HEADLESS-2";

  # --- Helper to find Hyprland Socket ---
  findSocket = ''
    if [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
      _HYPR_DIR="$XDG_RUNTIME_DIR/hypr"
      if [ ! -d "$_HYPR_DIR" ]; then
        _HYPR_DIR="/run/user/$(id -u)/hypr"
      fi
      export HYPRLAND_INSTANCE_SIGNATURE=$(ls -1 "$_HYPR_DIR" 2>/dev/null | grep -v "\.lock" | head -n 1)
      if [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        echo "Error: Could not detect active Hyprland instance."
        exit 1
      fi
      echo "Targeting Hyprland Instance: $HYPRLAND_INSTANCE_SIGNATURE"
    fi
  '';

  # --- Script 1: Enter Remote Mode ---
  remoteModeScript = pkgs.writeShellScriptBin "remote-mode" ''
    ${findSocket}
    # Ensure standard tools and Hyprland are in PATH
    export PATH=${makeBinPath [pkgs.jq pkgs.procps pkgs.hyprland]}:$PATH

    # --- Resolution Logic ---
    MODE="1920x1080@60"
    if [[ "$1" == "4k" ]]; then
      MODE="3840x2160@60"
      echo ">> Mode Selected: 4K ($MODE)"
    elif [[ "$1" == "1440p" ]]; then
      MODE="2560x1440@60"
      echo ">> Mode Selected: 1440p ($MODE)"
    else
      echo ">> Mode Selected: 1080p (Default)"
    fi

    echo "Activating Remote Mode..."

    # 1. Create headless output
    if ! hyprctl monitors | grep -q "${headlessName}"; then
      echo "Creating Headless Output: ${headlessName}"
      hyprctl output create headless ${headlessName}
    fi

    # 2. Force Resolution & Position (20,000 to avoid overlap)
    hyprctl keyword monitor ${headlessName},$MODE,20000x0,1

    # 3. Reload Wallpaper
    hyprctl dispatch exec "${pkgs.hyprpaper}/bin/hyprpaper"

    # 4. Move Configured Workspaces
    # We convert the Nix list to a space-separated string
    TARGET_WORKSPACES="${toString cfg.settings.workspaces}"
    ACTIVE_WS=$(hyprctl workspaces -j | jq -r '.[].id')

    for ws in $TARGET_WORKSPACES; do
      if echo "$ACTIVE_WS" | grep -q "^$ws$"; then
        echo "Moving workspace $ws to ${headlessName}"
        hyprctl dispatch moveworkspacetomonitor $ws ${headlessName}
      fi
    done

    # 5. DISABLE Configured Physical Monitors
    TARGET_MONITORS="${toString cfg.settings.physicalMonitors}"
    for mon in $TARGET_MONITORS; do
      echo "Disabling physical monitor: $mon"
      hyprctl keyword monitor $mon,disable
    done

    # 6. Restart VNC on Headless
    echo "Restarting VNC on ${headlessName}..."
    pkill wayvnc || true
    sleep 0.5
    hyprctl dispatch exec "${pkgs.wayvnc}/bin/wayvnc --output=${headlessName}"

    # 7. Dynamic Sunshine Config
    sleep 1
    HEADLESS_ID=$(hyprctl monitors -j | jq -r '.[] | select(.name == "${headlessName}") | .id')

    if [ -n "$HEADLESS_ID" ]; then
      echo "Configuring Sunshine to use Monitor ID: $HEADLESS_ID"
      mkdir -p ~/.config/sunshine
      echo "output_name = $HEADLESS_ID" > ~/.config/sunshine/sunshine.conf
    fi

    # 8. Restart Sunshine
    echo "Restarting Sunshine..."
    systemctl --user restart sunshine
  '';

  # --- Script 2: Enter Local Mode (Revert) ---
  localModeScript = pkgs.writeShellScriptBin "local-mode" ''
    ${findSocket}
    export PATH=${makeBinPath [pkgs.jq pkgs.procps pkgs.hyprland]}:$PATH

    echo "Restoring Local Mode..."

    # 1. EXECUTE RESTORE COMMANDS (Injected from Config)
    echo "Executing host-specific restore commands..."
    ${cfg.settings.restoreCommands}

    echo "Physical monitors re-enabled."

    # 2. Move Workspaces Back
    sleep 2
    TARGET_WORKSPACES="${toString cfg.settings.workspaces}"
    ACTIVE_WS=$(hyprctl workspaces -j | jq -r '.[].id')

    for ws in $TARGET_WORKSPACES; do
      if echo "$ACTIVE_WS" | grep -q "^$ws$"; then
        echo "Moving workspace $ws back to ${cfg.settings.primaryMonitor}"
        hyprctl dispatch moveworkspacetomonitor $ws ${cfg.settings.primaryMonitor}
      fi
    done

    # 3. Remove Headless Output
    if hyprctl monitors | grep -q "${headlessName}"; then
      echo "Removing Headless Output: ${headlessName}"
      hyprctl output remove ${headlessName}
    fi

    # 4. Restore Standard VNC
    echo "Restoring Standard VNC..."
    pkill wayvnc || true
    hyprctl dispatch exec wayvnc

    # 5. Reset Sunshine
    if [ -f ~/.config/sunshine/sunshine.conf ]; then
      rm ~/.config/sunshine/sunshine.conf
      echo "Reset Sunshine config."
      systemctl --user restart sunshine
    fi
  '';
in {
  options.homelab.remote-desktop = {
    enable = mkEnableOption "Enable Hyprland Remote Desktop Logic";

    settings = {
      workspaces = mkOption {
        type = types.listOf (types.oneOf [types.int types.str]);
        default = [1 2 3 4];
        description = "List of workspace IDs to move to the remote session.";
      };

      physicalMonitors = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of physical monitor names to disable in remote mode.";
      };

      primaryMonitor = mkOption {
        type = types.str;
        default = "0";
        description = "Monitor name/ID to return workspaces to in local mode.";
      };

      restoreCommands = mkOption {
        type = types.lines;
        default = "hyprctl reload";
        description = "Bash commands to execute to restore physical monitor layout (e.g. hyprctl keyword monitor ...).";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      remoteModeScript
      localModeScript
      pkgs.jq
      pkgs.procps
    ];

    wayland.windowManager.hyprland.settings = {
      bind = [
        "$mod SHIFT, D, exec, ${localModeScript}/bin/local-mode"
      ];
    };
  };
}
