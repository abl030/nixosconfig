{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.theme;
  # Helper: Hex to RGB
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

  # Colors from your central theme
  bg = toRGB cfg.colors.background;
  bgAlt = toRGB cfg.colors.backgroundAlt;
  fg = toRGB cfg.colors.foreground;
  accent = toRGB cfg.colors.primary;
  secondary = toRGB cfg.colors.secondary;
  border = toRGB cfg.colors.border;

  # The .colors file content
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
  options.homelab.theme = {
    # We add a new option here to allow other modules (like dolphin.nix)
    # to inject their own settings into kdeglobals.
    kdeglobals = {
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra configuration lines to append to kdeglobals";
      };
    };
  };

  config = {
    # 1. Install Qt/KDE Foundation Packages
    home.packages = with pkgs; [
      qt6Packages.qt6ct
      kdePackages.breeze
      kdePackages.breeze-icons
      qt6Packages.qtwayland
      dconf
    ];

    home.sessionVariables = {
      QT_PLUGIN_PATH =
        "${pkgs.kdePackages.breeze}/lib/qt-6/plugins:"
        + "${config.home.profileDirectory}/lib/qt-6/plugins";
    };

    # 2. Config Files Generation
    xdg = {
      # The Color Scheme File (Source of Truth for KDE apps)
      dataFile."color-schemes/NixOSTheme.colors".text = schemeText;

      configFile = {
        # qt6ct config
        "qt6ct/qt6ct.conf".text = ''
          [Appearance]
          custom_palette=false
          icon_theme=breeze-dark
          standard_dialogs=default
          style=Breeze

          [Interface]
          menus_have_icons=true
          toolbutton_style=4
        '';

        # kdeglobals: The System + Theme Settings
        # We merge the base settings with anything added via `extraConfig`
        "kdeglobals".text = ''
          [General]
          ColorScheme=NixOSTheme
          Name=NixOSTheme
          shadeSortColumn=true

          [KDE]
          SingleClick=true

          [Icons]
          Theme=breeze-dark

          [UiSettings]
          ColorScheme=NixOSTheme

          ${cfg.kdeglobals.extraConfig}
        '';
      };
    };
  };
}
