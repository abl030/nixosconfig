{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}:
with lib; let
  cfg = config.homelab.hyprland;
  inherit (hostConfig) user;
in {
  # 1. Import storage (UDisks2) so Dolphin can mount drives
  imports = [
    ../system/storage.nix
  ];

  options.homelab.hyprland = {
    enable = mkEnableOption "Enable Hyprland Unified Configuration";
  };

  config = mkIf cfg.enable {
    # ====================================================
    # SYSTEM CONFIGURATION (NixOS)
    # ====================================================

    # FIX: Link the Plasma Applications Menu
    # This file allows Dolphin/KService to index .desktop files properly.
    environment.etc."xdg/menus/applications.menu".source = "${pkgs.kdePackages.plasma-workspace}/etc/xdg/menus/plasma-applications.menu";

    # Turn on our storage helpers for Dolphin automounting
    homelab.storage.enable = true;

    # --- ENVIRONMENT VARIABLES (System Authority) ---
    environment.sessionVariables = {
      # Use the KDE platform theme plugin (works outside Plasma)
      QT_QPA_PLATFORMTHEME = "KDE";

      # Critical for Dolphin "Open With" and MIME integration
      XDG_MENU_PREFIX = "plasma-";
    };

    # Hyprland compositor + Xwayland
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    # SDDM on Wayland
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    # Leave X server enabled (some apps and tools still want it)
    services.xserver.enable = true;

    # Portals for screensharing etc.
    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    # PAM entry so hyprlock can authenticate
    security.pam.services.hyprlock = {};

    # ====================================================
    # USER CONFIGURATION (Home Manager)
    # ====================================================
    # We dynamically target the user defined in hosts.nix
    home-manager.users.${user} = {
      lib,
      pkgs,
      config,
      ...
    }: let
      # Import config values from the HM context
      vncCfg =
        config.homelab.vnc or {
          enable = false;
          output = "";
        };
      idleCfg = config.homelab.hypridle or {enable = false;};
      paperCfg = config.homelab.hyprpaper or {enable = false;};

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
      # Import existing HM helper modules
      # Note: qt-theme.nix is now imported globally via default.nix
      imports = [
        ../../../home-manager/display/theme.nix
        ../../../home-manager/display/waybar.nix
        ../../../home-manager/display/wayvnc.nix
        ../../../home-manager/display/hypridle.nix
        ../../../home-manager/display/hyprpaper.nix
      ];

      # Enable the modules we just imported
      homelab = {
        waybar.enable = true;
        hyprpaper.enable = true;
        qt.enable = true;
      };

      # 1. Install Ecosystem Packages
      home.packages = with pkgs;
        [
          # Core
          ghostty
          # wofi    <-- REMOVED
          dunst
          libnotify

          # System Settings GUIs
          pavucontrol
          blueman

          # Utilities
          wl-clipboard
          cliphist
          hyprpicker
          grim
          slurp

          # Polkit Agent
          kdePackages.polkit-kde-agent-1

          (pkgs.writeShellScriptBin "plexamp-debug" ''
            echo "--- ENVIRONMENT (ROFI) ---" > /tmp/plexamp-debug.log
            env >> /tmp/plexamp-debug.log
            echo "--- LAUNCHING PLEXAMP ---" >> /tmp/plexamp-debug.log
            ${pkgs.plexamp}/bin/plexamp >> /tmp/plexamp-debug.log 2>&1
          '')
        ]
        ++ [
          pkgs.hyprlock
        ]
        ++ optionals vncCfg.enable [wayvnc];

      # 2. Configure Hyprlock, Portals & Audio
      xdg = {
        configFile = {
          "hypr/hyprlock.conf".text = ''
            general {
              immediate_render = false
              hide_cursor = false
            }
            auth {
              pam:enabled = true
              pam:module = hyprlock
            }
            background {
              monitor =
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

          # CONFIG: Auto-switch to Bluetooth/USB audio when connected
          "pipewire/pipewire-pulse.conf.d/switch-on-connect.conf".text = ''
            pulse.cmd = [
              { cmd = "load-module" args = "module-switch-on-connect" }
            ]
          '';
        };

        portal = {
          enable = true;
          extraPortals = [
            pkgs.xdg-desktop-portal-hyprland
            pkgs.kdePackages.xdg-desktop-portal-kde # <--- The Missing Piece
            pkgs.xdg-desktop-portal-gtk # Fallback for GTK apps
          ];
          config = {
            common = {
              # Use Hyprland for screenshots/screencasts
              # Use KDE for file dialogs (matching your theme)
              default = ["hyprland"];
              "org.freedesktop.impl.portal.FileChooser" = ["kde"];
              "org.freedesktop.impl.portal.OpenURI" = ["kde"];
              "org.freedesktop.impl.portal.Secret" = ["kde"];
            };
          };
        };
      };

      # 3. Configure Hyprland
      wayland.windowManager.hyprland = {
        enable = true;
        package = pkgs.hyprland;
        portalPackage = pkgs.xdg-desktop-portal-hyprland;
        # FIX: Pass all environment variables to D-Bus/Systemd
        # This ensures Dolphin sees the same PATH as your terminal
        systemd.enable = true;
        systemd.variables = ["--all"];

        settings = {
          "$mod" = "SUPER";
          "$terminal" = "ghostty";
          "$menu" = "rofi -show drun"; # <-- UPDATED

          exec-once =
            [
              "hyprlock --immediate-render"
              "waybar"
              "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
              "wl-paste --watch cliphist store"
              "blueman-applet"
              # Starts the activity manager so "Recent Files" works in Dolphin
              # "${pkgs.kdePackages.kactivitymanagerd}/bin/kactivitymanagerd"
              "${pkgs.kdePackages.kactivitymanagerd}/libexec/kactivitymanagerd"
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

            # Quick Settings
            "$mod, A, exec, pavucontrol"
            "$mod, B, exec, blueman-manager"

            # Window Management
            "$mod, Q, killactive,"
            "$mod, F, fullscreen,"
            "$mod, T, togglefloating,"
            "$mod, O, pseudo,"
            "$mod, U, togglesplit,"
            "$mod, G, togglegroup,"

            # Clipboard / Screenshots
            # UPDATED: Use Rofi for clipboard history
            "$mod, V, exec, cliphist list | rofi -dmenu | cliphist decode | wl-copy"
            "$mod, P, exec, hyprpicker -a"
            ", Print, exec, grim -g \"$(slurp)\" - | wl-copy"
            "SHIFT, Print, exec, grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +'%Y%m%d_%H%M%S').png"

            # Scratchpad
            "$mod, S, togglespecialworkspace, magic"
            "$mod ALT, S, movetoworkspace, special:magic"

            # Focus
            "$mod, H, movefocus, l"
            "$mod, L, movefocus, r"
            "$mod, K, movefocus, u"
            "$mod, J, movefocus, d"

            # Move Window
            "$mod SHIFT, H, movewindow, l"
            "$mod SHIFT, L, movewindow, r"
            "$mod SHIFT, K, movewindow, u"
            "$mod SHIFT, J, movewindow, d"

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
            # "$mod, Tab, workspace, m+1"
            "$mod, Tab, exec, rofi -show window"

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
  };
}
