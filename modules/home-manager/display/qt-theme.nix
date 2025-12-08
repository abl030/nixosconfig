{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.theme;

  # --- 1. Color Logic (Hex -> RGB) ---
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

  # Colors
  bg = toRGB cfg.colors.background;
  bgAlt = toRGB cfg.colors.backgroundAlt;
  fg = toRGB cfg.colors.foreground;
  accent = toRGB cfg.colors.primary;
  secondary = toRGB cfg.colors.secondary;
  border = toRGB cfg.colors.border;

  accentRGB = accent;

  # --- 2. The Palette Block (Injected into both .colors and kdeglobals) ---
  commonPalette = ''
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

  schemeText = ''
    [General]
    Name=NixOSTheme
    ColorScheme=NixOSTheme
    ${commonPalette}
  '';
in {
  options.homelab.theme = {
    kdeglobals = {
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra configuration lines to append to kdeglobals";
      };
    };
  };

  config = {
    # 3. Install Packages
    home.packages = with pkgs; [
      # Core Theme Tools
      qt6Packages.qt6ct
      qt6Packages.qtwayland

      # Icons & Styles
      kdePackages.breeze
      kdePackages.breeze-icons

      # CRITICAL: This package provides the "KDE" platform theme plugin
      # Without this, QT_QPA_PLATFORMTHEME="KDE" fails and falls back to generic.
      kdePackages.plasma-integration

      # Optional: QML styling
      kdePackages.qqc2-desktop-style
    ];

    # 4. Session Variables
    home.sessionVariables = {
      QT_QPA_PLATFORMTHEME = "KDE";
      XDG_MENU_PREFIX = "plasma-";

      # Ensure the system finds the plugins we just installed
      QT_PLUGIN_PATH =
        "${pkgs.kdePackages.breeze}/lib/qt-6/plugins:"
        + "${pkgs.kdePackages.plasma-integration}/lib/qt-6/plugins:"
        + "${config.home.profileDirectory}/lib/qt-6/plugins";
    };

    # 5. Config Files
    xdg = {
      dataFile."color-schemes/NixOSTheme.colors".text = schemeText;

      configFile = {
        "qt6ct/qt6ct.conf".text = ''
          [Appearance]
          custom_palette=false
          icon_theme=breeze
          standard_dialogs=default
          style=Breeze

          [Interface]
          menus_have_icons=true
          toolbutton_style=4
        '';

        "kdeglobals".text = ''
          [General]
          ColorScheme=NixOSTheme
          Name=NixOSTheme
          shadeSortColumn=true
          AccentColor=${accentRGB}

          [KDE]
          SingleClick=true

          [Icons]
          # "breeze" is the adaptive theme that takes colors from kdeglobals.
          # "breeze-dark" forces hardcoded colors.
          Theme=breeze

          [UiSettings]
          ColorScheme=NixOSTheme

          ${commonPalette}

          ${cfg.kdeglobals.extraConfig}
        '';
      };
    };
  };
}
