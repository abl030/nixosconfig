{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;

  breezeDarkColors = "${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors";
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

    home = {
      # --- PACKAGES ---
      packages = with pkgs; [
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
        kdePackages.calligra
        shared-mime-info
      ];

      # --- Environment Variables ---
      sessionVariables = {
        QT_QPA_PLATFORMTHEME = "qt6ct";
        QT_QPA_PLATFORM = "wayland";
        QT_PLUGIN_PATH = "${config.home.profileDirectory}/lib/qt-6/plugins:$QT_PLUGIN_PATH";
      };

      # --- ACTIVATION SCRIPT ---
      # This runs every time you 'home-manager switch'.
      # UPDATED LOGIC: Respects existing user settings.
      activation.configureKdeGlobals = lib.hm.dag.entryAfter ["writeBoundary"] ''
        verboseEcho "Configuring Mutable KDE Globals..."

        DEST="$HOME/.config/kdeglobals"
        SOURCE="${breezeDarkColors}"

        # 1. If it is a symlink (from old Nix generation), remove it so we can create a real file.
        if [ -L "$DEST" ]; then
          verboseEcho "Removing read-only kdeglobals symlink..."
          rm "$DEST"
        fi

        # 2. If the file does NOT exist, create it from the template.
        # This ensures we don't overwrite your settings if the file is already there.
        if [ ! -f "$DEST" ]; then
             verboseEcho "Initializing kdeglobals from Breeze Dark template..."
             cat "$SOURCE" > "$DEST"
        fi

        # 3. Apply the "White Background" Fix safely.
        # We grep to see if the fix is already there. If not, we append it.
        # This allows the file to persist across generations without losing the fix.
        if ! grep -q "BackgroundNormal=30,31,33" "$DEST"; then
          verboseEcho "Applying White Background Fix..."
          echo "" >> "$DEST"
          echo "[Colors:View]" >> "$DEST"
          echo "BackgroundNormal=30,31,33" >> "$DEST"
          echo "BackgroundAlternate=35,36,38" >> "$DEST"
        fi

        # 4. CRITICAL: Make it writable so Dolphin can save settings
        chmod 644 "$DEST"
      '';
    };

    # --- Declarative File Synthesis (Existing logic) ---
    xdg = {
      configFile = {
        # "kdeglobals".text = ... (Logic moved to activation script above)

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
