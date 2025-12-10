{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  # --- Configuration ---
  headlessName = "HEADLESS-2";
  # Resolution is now handled dynamically in the script
  remoteWorkspaces = "1 2 3 4";
  primaryMonitor = "DP-3";

  physicalMonitors = "HDMI-A-2 DP-3 HDMI-A-3";

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
    export PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:$PATH

    # --- Resolution Logic ---
    # Default
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
    # ------------------------

    echo "Activating Remote Mode..."

    # 1. Create headless output
    if ! ${pkgs.hyprland}/bin/hyprctl monitors | grep -q "${headlessName}"; then
      echo "Creating Headless Output: ${headlessName}"
      ${pkgs.hyprland}/bin/hyprctl output create headless ${headlessName}
    fi

    # 2. Force Resolution & Position (20,000 to avoid overlap)
    ${pkgs.hyprland}/bin/hyprctl keyword monitor ${headlessName},$MODE,20000x0,1

    # 3. Reload Wallpaper
    ${pkgs.hyprland}/bin/hyprctl dispatch exec "${pkgs.hyprpaper}/bin/hyprpaper"

    # 4. Move Workspaces
    ACTIVE_WS=$(${pkgs.hyprland}/bin/hyprctl workspaces -j | jq -r '.[].id')
    for ws in ${remoteWorkspaces}; do
      if echo "$ACTIVE_WS" | grep -q "^$ws$"; then
        echo "Moving workspace $ws to ${headlessName}"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor $ws ${headlessName}
      fi
    done

    # 5. DISABLE Physical Monitors
    for mon in ${physicalMonitors}; do
      echo "Disabling physical monitor: $mon"
      ${pkgs.hyprland}/bin/hyprctl keyword monitor $mon,disable
    done

    # 6. Restart VNC on Headless
    echo "Restarting VNC on ${headlessName}..."
    pkill wayvnc || true
    sleep 0.5
    ${pkgs.hyprland}/bin/hyprctl dispatch exec "${pkgs.wayvnc}/bin/wayvnc --output=${headlessName}"

    # 7. Dynamic Sunshine Config
    sleep 1
    HEADLESS_ID=$(${pkgs.hyprland}/bin/hyprctl monitors -j | jq -r '.[] | select(.name == "${headlessName}") | .id')

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
    export PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:$PATH

    echo "Restoring Local Mode..."

    # 1. RE-ENABLE Physical Monitors
    ${pkgs.hyprland}/bin/hyprctl keyword monitor HDMI-A-2,1920x1080@75,0x0,1,transform,3
    ${pkgs.hyprland}/bin/hyprctl keyword monitor DP-3,2560x1440@144,1080x0,1
    ${pkgs.hyprland}/bin/hyprctl keyword monitor HDMI-A-3,1920x1080@60,3640x0,1

    echo "Physical monitors re-enabled."

    # 2. Move Workspaces Back
    sleep 2
    ACTIVE_WS=$(${pkgs.hyprland}/bin/hyprctl workspaces -j | jq -r '.[].id')
    for ws in ${remoteWorkspaces}; do
      if echo "$ACTIVE_WS" | grep -q "^$ws$"; then
        echo "Moving workspace $ws back to ${primaryMonitor}"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor $ws ${primaryMonitor}
      fi
    done

    # 3. Remove Headless Output
    if ${pkgs.hyprland}/bin/hyprctl monitors | grep -q "${headlessName}"; then
      echo "Removing Headless Output: ${headlessName}"
      ${pkgs.hyprland}/bin/hyprctl output remove ${headlessName}
    fi

    # 4. Restore Standard VNC
    echo "Restoring Standard VNC..."
    pkill wayvnc || true
    ${pkgs.hyprland}/bin/hyprctl dispatch exec wayvnc

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
  };

  config = mkIf config.homelab.remote-desktop.enable {
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
