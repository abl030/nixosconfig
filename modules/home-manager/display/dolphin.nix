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
    (hexToInt.${c1} * 16) + (hexToInt.${c2});

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

  # --- SHARED .colors CONTENT (used by Dolphin + Qt/KDE) ---
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

        # Thumbnailers (already installed, no changes)
        kdePackages.kdegraphics-thumbnailers
        kdePackages.ffmpegthumbs
        kdePackages.kdesdk-thumbnailers
        kdePackages.kio-extras
        kdePackages.calligra
        shared-mime-info
      ];

      sessionVariables = {
        QT_PLUGIN_PATH =
          "${pkgs.kdePackages.breeze}/lib/qt-6/plugins:"
          + "${config.home.profileDirectory}/lib/qt-6/plugins";
      };
    };

    xdg = {
      configFile = {
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

          [PreviewSettings]
          # Remote previews: 50 GiB
          MaximumRemoteSize=53687091200

          # Local: effectively unlimited (~100 GiB)
          MaximumSize=107374182400

          # Enable thumbnails in file dialogs and friends
          UseFileThumbnails=true

          # Enable folder previews, including remote ones
          EnableRemoteFolderThumbnail=true

          camera=true
          file=true
          fonts=true

          # Plugins: superset to tick all relevant document/office/ebook/translation/image types
          # - opendocumentthumbnail: OpenDocument
          # - comicbookthumbnail: comic archives
          # - windowsimagethumbnail, windowsexethumbnail: Windows images/EXEs
          # - directorythumbnail: folder previews
          # - rawthumbnail, exrthumbnail, svgthumbnail, imagethumbnail, jpegthumbnail: image formats
          # - appimagethumbnail: AppImage
          # - audiothumbnail: audio
          # - blenderthumbnail: Blender .blend
          # - ebookthumbnail, mobithumbnail: eBooks / Mobipocket
          # - kraorathumbnail: Krita / OpenRaster
          # - gettextthumbnail: Gettext translation files
          # - gsthumbnail, ffmpegthumbs: video previews
          Plugins=appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,desktopthumbnail,directorythumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,kraorathumbnail,mobithumbnail,opendocumentthumbnail,rawthumbnail,svgthumbnail,textthumbnail,windowsimagethumbnail,windowsexethumbnail,gsthumbnail,ffmpegthumbs,gettextthumbnail
        '';
      };

      dataFile = {
        "color-schemes/NixOSTheme.colors".text = schemeText;
      };

      portal = {
        enable = true;
        extraPortals = [pkgs.xdg-desktop-portal-gtk];
        config.common.default = ["hyprland" "gtk"];
      };
    };
  };
}
