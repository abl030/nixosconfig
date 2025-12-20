{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.theme;
  qtCfg = config.homelab.qt;

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

  # Colors from Theme
  bg = toRGB cfg.colors.background;
  bgAlt = toRGB cfg.colors.backgroundAlt;
  fg = toRGB cfg.colors.foreground;
  accent = toRGB cfg.colors.primary;
  secondary = toRGB cfg.colors.secondary;
  border = toRGB cfg.colors.border;

  accentRGB = accent;

  # --- 2. The Palette Block ---
  # We inject this into kdeglobals so the KDE Platform Theme plugin
  # can read the "Selection" color and apply it to Breeze Icons.
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
  options.homelab = {
    qt.enable = mkEnableOption "Enable Qt Theming & Integration";

    theme.kdeglobals = {
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra configuration lines to append to kdeglobals";
      };
    };
  };

  config = mkIf qtCfg.enable {
    # 3. Install Packages & Session Variables (Consolidated)
    home = {
      packages = with pkgs; [
        qt6Packages.qtwayland

        # Icons & Styles
        kdePackages.breeze
        kdePackages.breeze-icons

        # KDE Platform Integration (The mechanism that makes this work)
        kdePackages.plasma-integration
        kdePackages.qqc2-desktop-style
      ];

      sessionVariables = {
        # Force KDE integration (Dolphin will read kdeglobals)
        QT_QPA_PLATFORMTHEME = "KDE";
        XDG_MENU_PREFIX = "plasma-";

        QT_PLUGIN_PATH =
          "${pkgs.kdePackages.breeze}/lib/qt-6/plugins:"
          + "${pkgs.kdePackages.plasma-integration}/lib/qt-6/plugins:"
          + "${config.home.profileDirectory}/lib/qt-6/plugins";

        # 1. Force the KDE6 integration plugin.
        # This reads your 'kdeglobals' for UI colors (Dark Menus).
        # If LO fails to launch, try "qt6" or "kf5" instead.
        SAL_USE_VCLPLUGIN = "kf6";

        # 2. Force Dark Icons.
        # Without this, you might get dark icons on your dark menus.
        SAL_ICON_THEME = "breeze";
      };
    };

    # 5. Config Files (REMOVED: qt6ct.conf)
    xdg = {
      dataFile."color-schemes/NixOSTheme.colors".text = schemeText;

      configFile = {
        "kdeglobals".text = ''
          [General]
          ColorScheme=NixOSTheme
          Name=NixOSTheme
          shadeSortColumn=true
          AccentColor=${accentRGB}

          [KDE]
          SingleClick=true

          [Icons]
          Theme=breeze

          [UiSettings]
          ColorScheme=NixOSTheme

          # NOTE: To manually force icon colors independent of the Accent,
          # you would add a [DesktopIcons] section here with DefaultColor=R,G,B.
          # Since we want them to match the accent, we rely on standard inheritance.

          ${commonPalette}

          ${cfg.kdeglobals.extraConfig}
        '';
      };
    };
  };
}
