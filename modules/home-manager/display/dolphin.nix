{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;

  breezeDarkColors = "${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors";

  kdeglobalsOverride = ''
    [Colors:View]
    BackgroundNormal=30,31,33
    BackgroundAlternate=35,36,38
  '';
in {
  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager with Declarative Dark Mode";
  };

  config = mkIf cfg.enable {
    # --- AUTOMOUNTING SERVICE ---
    # Udiskie sits in the background, talks to UDisks2 (enabled in NixOS),
    # and automatically mounts USBs when plugged in.
    services.udiskie = {
      enable = true;
      tray = "auto"; # Only show tray icon if a device is mounted
      automount = true;
      notify = true; # Uses libnotify (dunst)
    };

    # --- PACKAGES ---
    home.packages = with pkgs; [
      # Core App
      kdePackages.dolphin
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kio-admin

      # --- NEW: Archive Management ---
      kdePackages.ark # The actual archiving tool (Zip/Tar/7z)

      # --- NEW: Service Menus (Context Menu Fix) ---
      # 'kservice' is strictly required for Dolphin to find Ark's
      # "Extract Here" and "Compress" right-click actions in a non-Plasma session.
      kdePackages.kservice

      # Theming Infrastructure
      qt6Packages.qt6ct
      kdePackages.breeze
      kdePackages.breeze-icons
      qt6Packages.qtwayland
      dconf

      # Thumbnailers
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.qtsvg
      kdePackages.qtimageformats
    ];

    # --- Environment Variables ---
    home.sessionVariables = {
      QT_QPA_PLATFORMTHEME = "qt6ct";
      QT_QPA_PLATFORM = "wayland";
    };

    # --- Declarative File Synthesis (Existing logic) ---
    xdg = {
      configFile = {
        "kdeglobals".text = (builtins.readFile breezeDarkColors) + "\n" + kdeglobalsOverride;

        "qt6ct/qt6ct.conf".text = ''
          [Appearance]
          color_scheme_path=${config.xdg.configHome}/kdeglobals
          custom_palette=true
          icon_theme=breeze-dark
          standard_dialogs=default
          style=Breeze

          [Interface]
          cursor_flash_time=1000
          dialog_buttons_have_icons=1
          double_click_interval=400
          gui_effects=@Invalid()
          keyboard_scheme=2
          menus_have_icons=true
          show_shortcuts_in_context_menus=true
          stylesheets=@Invalid()
          toolbutton_style=4
          underline_shortcut=1
          wheel_scroll_lines=3
        '';
      };

      portal = {
        enable = true;
        extraPortals = [pkgs.xdg-desktop-portal-gtk];
        config.common.default = ["hyprland" "gtk"];
      };
    };
  };
}
