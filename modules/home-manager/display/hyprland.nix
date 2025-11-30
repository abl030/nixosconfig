{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
  vncCfg = config.homelab.vnc;
  idleCfg = config.homelab.hypridle or {enable = false;};
  paperCfg = config.homelab.hyprpaper or {enable = false;};

  # Inherit colors to satisfy statix
  inherit (config.homelab.theme) colors;

  rgb = alpha: hex: let
    hexNoHash =
      if lib.hasPrefix "#" hex
      then builtins.substring 1 (builtins.stringLength hex) hex
      else hex;
  in
    if alpha != ""
    then "rgba(${hexNoHash}${alpha})"
    else "rgb(${hexNoHash})";
in {
  imports = [
    # inputs.hyprland.homeManagerModules.default # Removed to use standard HM module + pkgs.hyprland
    ./theme.nix
    ./waybar.nix
    ./wayvnc.nix
    ./hypridle.nix
    ./hyprpaper.nix
  ];

  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland User Configuration";
  };

  config = mkIf cfg.enable {
    homelab.waybar.enable = true;
    homelab.hyprpaper.enable = true;

    # 1. Install Ecosystem Packages
    home.packages = with pkgs;
      [
        # Core
        ghostty
        wofi
        dunst
        libnotify

        # Utilities
        wl-clipboard
        cliphist
        hyprpicker
        grim
        slurp

        # Polkit Agent
        kdePackages.polkit-kde-agent-1
      ]
      ++ [
        # Use Hyprlock from flake input to match graphics drivers
        # inputs.hyprlock.packages.${pkgs.system}.hyprlock
        pkgs.hyprlock
      ]
      ++ optionals vncCfg.enable [wayvnc];

    # 2. Configure Hyprlock
    # NOTE: "auth" block requires very recent hyprlock, which the flake input provides.
    xdg.configFile."hypr/hyprlock.conf".text = ''
      general {
        immediate_render = false   # FIX: Intel Arc stability
        hide_cursor = false
      }
      auth {
        pam:enabled = true
        pam:module = hyprlock
      }
      background {
        monitor =
        # path = screenshot
        blur_passes = 0            # FIX: Disable blur for Intel Arc
        color = ${rgb "" colors.background}
      }
      input-field {
        monitor =
        size = 300, 60
        position = 0, 0
        halign = center
        valign = center
        outer_color = ${rgb "" colors.primary}
        inner_color = ${rgb "" colors.backgroundAlt}
        font_color = ${rgb "" colors.foreground}

        fade_on_empty = false
        shadow_passes = 0          # FIX: Disable shadows for Intel Arc

        placeholder_text = Input Password...
      }
      label {
        monitor =
        text = Hello, $USER
        position = 0, -100
        halign = center
        valign = center
        font_size = 24
        color = ${rgb "" colors.foreground}
      }
    '';

    # 3. Configure Hyprland
    wayland.windowManager.hyprland = {
      enable = true;
      package = pkgs.hyprland; # inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      portalPackage = pkgs.xdg-desktop-portal-hyprland; # inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;

      settings = {
        "$mod" = "SUPER";
        "$terminal" = "ghostty";
        "$menu" = "wofi --show drun";

        exec-once =
          [
            # FIX: Force CPU rendering on startup
            "WLR_RENDERER=pixman hyprlock"

            "waybar"
            "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
            "wl-paste --watch cliphist store"
          ]
          ++ optionals idleCfg.enable ["hypridle"]
          ++ optionals paperCfg.enable ["hyprpaper"]
          ++ optionals vncCfg.enable [
            (
              if vncCfg.output != ""
              then "wayvnc --output=${vncCfg.output}"
              else "wayvnc"
            )
          ];

        monitor = ",preferred,auto,auto";

        env = [
          "XCURSOR_SIZE,24"
          "NIXOS_OZONE_WL,1"
        ];

        general = {
          gaps_in = 5;
          gaps_out = 20;
          border_size = 2;
          "col.active_border" = "${rgb "ee" colors.primary} ${rgb "ee" colors.info} 45deg";
          "col.inactive_border" = "${rgb "aa" colors.border}";
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
          # System / Launchers
          "$mod, Return, exec, $terminal"
          "$mod, Space, exec, $menu"
          "$mod SHIFT, F, exec, dolphin"
          "$mod, M, exit,"

          # Utilities
          "$mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy"
          "$mod, P, exec, hyprpicker -a"
          ", Print, exec, grim -g \"$(slurp)\" - | wl-copy"
          "SHIFT, Print, exec, grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +'%Y%m%d_%H%M%S').png"

          # Window Management
          "$mod, W, killactive,"
          "$mod, F, fullscreen,"
          "$mod, T, togglefloating,"
          "$mod, O, pseudo,"
          "$mod, J, togglesplit,"
          "$mod, G, togglegroup,"

          # Scratchpad
          "$mod, S, togglespecialworkspace, magic"
          "$mod ALT, S, movetoworkspace, special:magic"

          # Focus
          "$mod, left, movefocus, l"
          "$mod, right, movefocus, r"
          "$mod, up, movefocus, u"
          "$mod, down, movefocus, d"

          # Move Window
          "$mod SHIFT, left, movewindow, l"
          "$mod SHIFT, right, movewindow, r"
          "$mod SHIFT, up, movewindow, u"
          "$mod SHIFT, down, movewindow, d"

          # Workspaces
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

          # Move to Workspace
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

          # Cycle Workspaces
          "$mod, Tab, workspace, m+1"
          "$mod SHIFT, Tab, workspace, m-1"

          # Scroll
          "$mod, mouse_down, workspace, e+1"
          "$mod, mouse_up, workspace, e-1"
        ];

        bindel = [
          ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
          ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
          ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          ", XF86MonBrightnessUp, exec, brightnessctl s 10%+"
          ", XF86MonBrightnessDown, exec, brightnessctl s 10%-"
        ];

        bindl = [
          ", XF86AudioPlay, exec, playerctl play-pause"
          ", XF86AudioNext, exec, playerctl next"
          ", XF86AudioPrev, exec, playerctl previous"
        ];

        bindm = [
          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, resizewindow"
        ];
      };
    };
  };
}
