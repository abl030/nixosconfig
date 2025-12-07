{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;

  # 1. Define path to the official Breeze Dark assets from the package
  breezeDarkColors = "${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors";

  # 2. Define the crucial override
  # This fixes the "White Background" bug by forcing the View background to dark gray (30,31,33).
  # We also set the Alternate background for list views.
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
    # --- Phase I: Dependencies ---
    home.packages = with pkgs; [
      # Core App
      kdePackages.dolphin
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kio-admin

      # Theming Infrastructure
      qt6Packages.qt6ct # The configuration tool
      kdePackages.breeze # The asset provider (Icons, Styles, Color Schemes)
      kdePackages.breeze-icons
      qt6Packages.qtwayland # Native Wayland rendering
      dconf # Required for GSettings/Portal compatibility

      # Thumbnailers
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.qtsvg
      kdePackages.qtimageformats
    ];

    # --- Phase II: Environment Variables ---
    home.sessionVariables = {
      # Tell Qt6 to use qt6ct to resolve themes (instead of expecting a running Plasma session)
      QT_QPA_PLATFORMTHEME = "qt6ct";
      # Force native Wayland instead of XWayland
      QT_QPA_PLATFORM = "wayland";
    };

    # --- Phase III: Declarative File Synthesis ---

    # 1. Synthesize ~/.config/kdeglobals
    # We read the official file and append our override to the end.
    xdg.configFile."kdeglobals".text =
      (builtins.readFile breezeDarkColors) + "\n" + kdeglobalsOverride;

    # 2. Synthesize ~/.config/qt6ct/qt6ct.conf
    # This ensures qt6ct actually selects the "Breeze" style and "Breeze" icon theme
    # without you having to open the GUI manually.
    xdg.configFile."qt6ct/qt6ct.conf".text = ''
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

    # --- Phase IV: Portals ---
    # Ensure the GTK portal exists so file pickers look correct in non-KDE apps too
    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.common.default = ["hyprland" "gtk"];
    };
  };
}
