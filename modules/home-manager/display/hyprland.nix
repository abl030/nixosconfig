{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
in {
  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland User Configuration";
  };

  config = mkIf cfg.enable {
    # 1. Install the packages we need for the user
    home.packages = with pkgs; [
      ghostty
      wofi
      dunst
      libnotify
      wl-clipboard
    ];

    # 2. Configure Hyprland
    wayland.windowManager.hyprland = {
      enable = true;

      # IMPORTANT: We set package to null because we enabled `programs.hyprland.enable = true`
      # in the system configuration. This prevents version conflicts or double installs.
      package = null;
      portalPackage = null;

      # 3. The Configuration (Translated from hyprland.conf to Nix)
      settings = {
        # Variables
        "$mod" = "SUPER";
        "$terminal" = "ghostty"; # <--- Your Ghostty requirement
        "$menu" = "wofi --show drun";

        # Monitor Settings
        monitor = ",preferred,auto,auto";

        # Environment Variables
        env = [
          "XCURSOR_SIZE,24"
          "NIXOS_OZONE_WL,1"
        ];

        # Look and Feel
        general = {
          gaps_in = 5;
          gaps_out = 20;
          border_size = 2;
          "col.active_border" = "rgba(33ccffee) rgba(00ff99ee) 45deg";
          "col.inactive_border" = "rgba(595959aa)";
          layout = "dwindle";
        };

        decoration = {
          rounding = 10;

          blur = {
            enabled = true;
            size = 3;
            passes = 1;
          };

          # Drop Shadow is now just 'shadow' in newer Hyprland versions
          # drop_shadow = true;
          # shadow_range = 4;
          # shadow_render_power = 3;
          # "col.shadow" = "rgba(1a1a1aee)";
        };

        animations = {
          enabled = true;
          bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
          animation = [
            "windows, 1, 7, myBezier"
            "windowsOut, 1, 7, default, popin 80%"
            "border, 1, 10, default"
            "borderangle, 1, 8, default"
            "fade, 1, 7, default"
            "workspaces, 1, 6, default"
          ];
        };

        dwindle = {
          pseudotile = true;
          preserve_split = true;
        };

        # Input config
        input = {
          kb_layout = "us";
          follow_mouse = 1;
          touchpad = {
            natural_scroll = true;
          };
        };

        # Keybindings
        bind = [
          "$mod, Q, exec, $terminal"
          "$mod, C, killactive,"
          "$mod, M, exit,"
          "$mod, E, exec, dolphin"
          "$mod, V, togglefloating,"
          "$mod, R, exec, $menu"
          "$mod, P, pseudo," # dwindle
          "$mod, J, togglesplit," # dwindle

          # Move focus with mod + arrow keys
          "$mod, left, movefocus, l"
          "$mod, right, movefocus, r"
          "$mod, up, movefocus, u"
          "$mod, down, movefocus, d"

          # Switch workspaces with mod + [0-9]
          "$mod, 1, workspace, 1"
          "$mod, 2, workspace, 2"
          "$mod, 3, workspace, 3"
          "$mod, 4, workspace, 4"
          "$mod, 5, workspace, 5"
          "$mod, 6, workspace, 6"
          "$mod, 7, workspace, 7"
          "$mod, 8, workspace, 8"
          "$mod, 9, workspace, 9"
          "$mod, 0, workspace, 10"

          # Move active window to a workspace with mod + SHIFT + [0-9]
          "$mod SHIFT, 1, movetoworkspace, 1"
          "$mod SHIFT, 2, movetoworkspace, 2"
          "$mod SHIFT, 3, movetoworkspace, 3"
          "$mod SHIFT, 4, movetoworkspace, 4"
          "$mod SHIFT, 5, movetoworkspace, 5"
          "$mod SHIFT, 6, movetoworkspace, 6"
          "$mod SHIFT, 7, movetoworkspace, 7"
          "$mod SHIFT, 8, movetoworkspace, 8"
          "$mod SHIFT, 9, movetoworkspace, 9"
          "$mod SHIFT, 0, movetoworkspace, 10"

          # Scroll through existing workspaces with mod + scroll
          "$mod, mouse_down, workspace, e+1"
          "$mod, mouse_up, workspace, e-1"
        ];

        # Mouse bindings
        bindm = [
          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, resizewindow"
        ];
      };
    };
  };
}
