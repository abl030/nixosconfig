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
    # Add the matching toggle here
    vnc = mkEnableOption "Enable WayVNC Server";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs;
      [
        ghostty
        wofi
        dunst
        libnotify
        wl-clipboard
        hyprlock
      ]
      ++ optionals cfg.vnc [wayvnc];

    # Create wayvnc config file
    # We bind to 0.0.0.0 to allow external connections.
    xdg.configFile."wayvnc/config" = mkIf cfg.vnc {
      text = ''
        address=0.0.0.0
        port=5900
        enable_auth=true
        enable_pam=true

        # Point to the runtime secrets mounted by System SOPS
        # Note: We use the names defined in sops.secrets
        private_key_file=/run/secrets/wayvnc_key
        certificate_file=/run/secrets/wayvnc_cert
      '';
    };

    # Simple hyprlock configuration
    xdg.configFile."hypr/hyprlock.conf".text = ''
      general {
        immediate_render = true
        hide_cursor = false
      }

      auth {
        pam:enabled = true
        pam:module = hyprlock
      }

      background {
        monitor =
        color = rgba(0, 0, 0, 1.0)
      }

      input-field {
        monitor =
        size = 300, 60
        position = 0, 0
        halign = center
        valign = center
      }

      label {
        monitor =
        text = Hello, $USER
        position = 0, -100
        halign = center
        valign = center
        font_size = 24
      }
    '';

    wayland.windowManager.hyprland = {
      enable = true;
      package = null;
      portalPackage = null;

      settings = {
        "$mod" = "SUPER";
        "$terminal" = "ghostty";
        "$menu" = "wofi --show drun";

        # Start hyprlock immediately on login, then wayvnc (if enabled)
        exec-once =
          ["hyprlock --immediate-render"]
          ++ optionals cfg.vnc ["wayvnc"];

        monitor = ",preferred,auto,auto";

        env = [
          "XCURSOR_SIZE,24"
          "NIXOS_OZONE_WL,1"
        ];

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

        input = {
          kb_layout = "us";
          follow_mouse = 1;
          touchpad = {
            natural_scroll = true;
          };
        };

        bind = [
          "$mod, Q, exec, $terminal"
          "$mod, C, killactive,"
          "$mod, M, exit,"
          "$mod, E, exec, dolphin"
          "$mod, V, togglefloating,"
          "$mod, R, exec, $menu"
          "$mod, P, pseudo,"
          "$mod, J, togglesplit,"
          "$mod, left, movefocus, l"
          "$mod, right, movefocus, r"
          "$mod, up, movefocus, u"
          "$mod, down, movefocus, d"
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
          "$mod, mouse_down, workspace, e+1"
          "$mod, mouse_up, workspace, e-1"
        ];

        bindm = [
          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, resizewindow"
        ];
      };
    };
  };
}
