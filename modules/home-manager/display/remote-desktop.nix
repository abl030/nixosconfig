{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  # --- Configuration ---
  headlessName = "HEADLESS-2";
  headlessRes = "1920x1080@60";
  remoteWorkspaces = "1 2 3 4";
  primaryMonitor = "DP-3";

  # Hardcoded list of physical monitors to Disable/Enable
  # We need this because once disabled, 'hyprctl monitors' won't list them anymore!
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

    echo "Activating Remote Mode..."

    # 1. Create headless output
    if ! ${pkgs.hyprland}/bin/hyprctl monitors | grep -q "${headlessName}"; then
      echo "Creating Headless Output: ${headlessName}"
      ${pkgs.hyprland}/bin/hyprctl output create headless ${headlessName}
    fi

    # 2. Force Resolution
    ${pkgs.hyprland}/bin/hyprctl keyword monitor ${headlessName},${headlessRes},0x0,1

    # 3. Reload Wallpaper (Fixes black background)
    # We run it directly in background, bypassing dispatcher issues
    nohup ${pkgs.hyprpaper}/bin/hyprpaper >/dev/null 2>&1 &

    # 4. Move Workspaces
    ACTIVE_WS=$(${pkgs.hyprland}/bin/hyprctl workspaces -j | jq -r '.[].id')
    for ws in ${remoteWorkspaces}; do
      if echo "$ACTIVE_WS" | grep -q "^$ws$"; then
        echo "Moving workspace $ws to ${headlessName}"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor $ws ${headlessName}
      fi
    done

    # 5. DISABLE Physical Monitors (The Fix)
    # This removes them from the compositor layout, forcing Sunshine to ignore them.
    for mon in ${physicalMonitors}; do
      echo "Disabling physical monitor: $mon"
      ${pkgs.hyprland}/bin/hyprctl keyword monitor $mon,disable
    done

    # 6. Restart VNC on Headless
    echo "Restarting VNC on ${headlessName}..."
    pkill wayvnc || true
    sleep 0.5
    # Bind explicitly to headless
    setsid ${pkgs.wayvnc}/bin/wayvnc --output=${headlessName} >/dev/null 2>&1 &

    # 7. Dynamic Sunshine Config
    # We must wait a moment for the disable commands to settle
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
    # We restore them to "preferred,auto,1" or specific configs if needed.
    # Based on your home.nix, we try to restore them to defaults or specific layouts.
    # To keep it simple and robust, we use 'preferred,auto,1'.
    # Hyprland's config will likely override positions on next reload, or this is enough.

    # Left (Portrait)
    ${pkgs.hyprland}/bin/hyprctl keyword monitor HDMI-A-2,1920x1080@75,0x0,1,transform,3
    # Middle (Primary)
    ${pkgs.hyprland}/bin/hyprctl keyword monitor DP-3,2560x1440@144,1080x0,1
    # Right
    ${pkgs.hyprland}/bin/hyprctl keyword monitor HDMI-A-3,1920x1080@60,3640x0,1

    echo "Physical monitors re-enabled."

    # 2. Move Workspaces Back
    # We wait a second for monitors to wake up
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

    # 4. Restore VNC (Standard Mode)
    echo "Restoring Standard VNC..."
    pkill wayvnc || true
    # We launch it via dispatch so it behaves like the config exec-once
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
