{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;
  theme = config.homelab.theme.colors;

  # --- HELPER: Hex to RGB Conversion ---
  hexToDec = v: let
    hexToInt = {
      "0" = 0;
      "1" = 1;
      "2" = 2;
      "3" = 3;
      "4" = 4;
      "5" = 5;
      "6" = 6;
      "7" = 7;
      "8" = 8;
      "9" = 9;
      "a" = 10;
      "b" = 11;
      "c" = 12;
      "d" = 13;
      "e" = 14;
      "f" = 15;
      "A" = 10;
      "B" = 11;
      "C" = 12;
      "D" = 13;
      "E" = 14;
      "F" = 15;
    };
    c1 = builtins.substring 0 1 v;
    c2 = builtins.substring 1 1 v;
  in
    (hexToInt.${c1} * 16) + hexToInt.${c2};

  toRGB = hex: let
    clean = lib.removePrefix "#" hex;
    r = toString (hexToDec (builtins.substring 0 2 clean));
    g = toString (hexToDec (builtins.substring 2 2 clean));
    b = toString (hexToDec (builtins.substring 4 2 clean));
  in "${r},${g},${b}";

  # --- COLOR MAPPING (from homelab.theme) ---
  bg = toRGB theme.background;
  bgAlt = toRGB theme.backgroundAlt;
  fg = toRGB theme.foreground;
  accent = toRGB theme.primary; # Orange
  secondary = toRGB theme.secondary; # Beige
  border = toRGB theme.border;

  # --- SHARED .colors CONTENT (used by both Dolphin + Qt/KDE) ---
  schemeText = ''
    [General]
    Name=NixOSTheme
    ColorScheme=NixOSTheme

    [Colors:Window]
    BackgroundNormal=${bg}
    BackgroundAlternate=${bgAlt}
    ForegroundNormal=${fg}
    ForegroundInactive=${border}
    ForegroundActive=${accent}
    DecorationFocus=${accent}
    DecorationHover=${secondary}

    [Colors:View]
    BackgroundNormal=${bg}
    BackgroundAlternate=${bgAlt}
    ForegroundNormal=${fg}
    ForegroundInactive=${border}
    ForegroundActive=${accent}
    DecorationFocus=${accent}
    DecorationHover=${secondary}

    [Colors:Button]
    BackgroundNormal=${bgAlt}
    BackgroundAlternate=${bg}
    ForegroundNormal=${fg}
    ForegroundInactive=${border}
    ForegroundActive=${accent}
    DecorationFocus=${accent}
    DecorationHover=${secondary}

    [Colors:Selection]
    BackgroundNormal=${accent}
    BackgroundAlternate=${secondary}
    ForegroundNormal=${bg}
    ForegroundInactive=${bg}
    ForegroundActive=${bg}
    DecorationFocus=${accent}
    DecorationHover=${secondary}

    [Colors:Tooltip]
    BackgroundNormal=${bgAlt}
    BackgroundAlternate=${bg}
    ForegroundNormal=${fg}
    ForegroundInactive=${border}
    ForegroundActive=${accent}
    DecorationFocus=${accent}
    DecorationHover=${secondary}

    [Colors:Complementary]
    BackgroundNormal=${bg}
    ForegroundNormal=${fg}

    [WM]
    activeBackground=${accent}
    activeForeground=${fg}
    inactiveBackground=${bgAlt}
    inactiveForeground=${border}
  '';
in {
  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager with Declarative Dark Mode";
  };

  config = mkIf cfg.enable {
    # --- AUTOMOUNTING SERVICE ---
    services.udiskie = {
      enable = true;
      tray = "auto";
      automount = true;
      notify = true;
    };

    home = {
      # --- PACKAGES ---
      packages = with pkgs; [
        # Core Dolphin + friends
        kdePackages.dolphin
        kdePackages.dolphin-plugins
        kdePackages.kio-extras
        kdePackages.kio-admin
        kdePackages.ark
        kdePackages.kservice

        # Theming infrastructure
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
        kdePackages.calligra
        shared-mime-info
      ];

      # Optional: plugin path hints for Breeze, mostly harmless
      sessionVariables = {
        QT_PLUGIN_PATH =
          "${pkgs.kdePackages.breeze}/lib/qt-6/plugins:"
          + "${config.home.profileDirectory}/lib/qt-6/plugins";
      };
    };

    xdg = {
      # ---------------------------
      # CONFIG FILES (~/.config)
      # ---------------------------
      configFile = {
        # 1) qt6ct: still installed, but colors now driven by our .colors file.
        # We explicitly *disable* custom palette so KDE/Breeze colors win.
        "qt6ct/qt6ct.conf".text = ''
          [Appearance]
          custom_palette=false
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

        # 2) Global KDE “pointer” to our color scheme + icon theme
        "kdeglobals".text = ''
          [General]
          ColorScheme=NixOSTheme
          Name=NixOSTheme
          shadeSortColumn=true

          [KDE]
          SingleClick=true

          [Icons]
          Theme=breeze-dark
        '';

        # 3) Dolphin-specific settings — THIS is what modern Dolphin reads.
        "dolphinrc".text = ''
          [UiSettings]
          ColorScheme=NixOSTheme

          [Icons]
          Theme=breeze-dark
        '';
      };

      # ---------------------------
      # DATA FILES (~/.local/share)
      # ---------------------------
      dataFile = {
        # 4) The actual color scheme file Dolphin + KDE will load
        "color-schemes/NixOSTheme.colors".text = schemeText;
      };

      # Portals for file dialogs etc. when under Hyprland
      portal = {
        enable = true;
        extraPortals = [pkgs.xdg-desktop-portal-gtk];
        config.common.default = ["hyprland" "gtk"];
      };
    };
  };
}
