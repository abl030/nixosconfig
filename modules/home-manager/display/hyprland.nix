{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
  vncCfg = config.homelab.vnc; # Access the sibling module configuration
in {
  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland User Configuration";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      ghostty
      wofi
      dunst
      libnotify
      wl-clipboard
      hyprlock
    ];

    # Hyprlock config (kept as is)
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
      settings = {
        "$mod" = "SUPER";
        "$terminal" = "ghostty";
        "$menu" = "wofi --show drun";

        # Check global VNC enable flag
        exec-once =
          ["hyprlock --immediate-render"]
          ++ optionals vncCfg.enable ["wayvnc"];

        monitor = ",preferred,auto,auto";
        # ... rest of your settings ...
        bind = [
          "$mod, Q, exec, $terminal"
          "$mod, M, exit,"
          # ... rest of binds
        ];
      };
    };
  };
}
