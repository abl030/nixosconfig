/*
===================================================================================
PDF VIEWING MODULE (Zathura, Sioyek, Okular)
===================================================================================

DESIGN DECISIONS:
1. "Slide Deck" Scrolling:
   - In Zathura and Sioyek, the Mouse Wheel is mapped strictly to "Next/Prev Page".
   - It does NOT scroll pixels. This provides a presentation-like feel.
   - Zooming is moved to <Ctrl + Mouse Wheel>.

2. Unified Clipboard (Zathura):
   - Highlighting text immediately copies to the System Clipboard (Ctrl+V compatible).
   - No need to Middle-Click to paste.

3. Theming (Dark Mode):
   - Zathura & Sioyek ignore the PDF's native white background by default.
   - They recolor the document using 'homelab.theme.colors'.
   - Okular uses the system Qt theme defined in 'qt-theme.nix'.

CHEAT SHEET / KEYMAPS:
-----------------------------------------------------------------------------------
| App     | Action               | Key Binding                                    |
|---------|----------------------|------------------------------------------------|
| Zathura | Toggle Dark Mode     | [i] (Recolor)                                  |
| Zathura | Reload File          | [r]                                            |
| Zathura | Zoom                 | Ctrl + Scroll                                  |
|---------|----------------------|------------------------------------------------|
| Sioyek  | Toggle Dark Mode     | [F8] (Toggle Custom Color)                     |
| Sioyek  | Smart Jump (Portal)  | [Right Click] on citation / link               |
| Sioyek  | Zoom                 | Ctrl + Scroll                                  |
|---------|----------------------|------------------------------------------------|
| Okular  | Manual Setup         | View > View Mode > Single Page                 |
|         |                      | View > Zoom > Fit Page                         |
-----------------------------------------------------------------------------------
*/
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.pdf;
  inherit (config.homelab.theme) colors;
in {
  options.homelab.pdf = {
    enable = mkEnableOption "Enable PDF Viewing Suite (Zathura, Sioyek, Okular)";
  };

  config = mkIf cfg.enable {
    # =========================================================
    # 1. ZATHURA
    # Best for: Quick keyboard-centric reading
    # =========================================================
    programs.zathura = {
      enable = true;

      options = {
        # --- Theming (Matches theme.nix) ---
        default-bg = colors.background;
        default-fg = colors.foreground;

        # UI Elements
        statusbar-bg = colors.backgroundAlt;
        statusbar-fg = colors.foreground;
        inputbar-bg = colors.background;
        inputbar-fg = colors.primary;

        # Document Recolor (Dark Mode)
        recolor = "true";
        recolor-lightcolor = colors.background;
        recolor-darkcolor = colors.foreground;

        # --- Clipboard Behavior ---
        # "clipboard" ensures text acts like Ctrl+C immediately.
        # By default, Linux uses "primary" (middle-click paste).
        selection-clipboard = "clipboard";

        # --- UX ---
        adjust-open = "best-fit"; # Open fitting width
        guioptions = "s"; # Hide scrollbars, show status bar
        scroll-step = 100; # Irrelevant due to mapping, but good backup
        zoom-step = 10;
      };

      # --- SCROLLING LOGIC ---
      # Button4 = Wheel Up, Button5 = Wheel Down
      mappings = {
        "<Button4>" = "navigate previous"; # Wheel Up -> Previous Page
        "<Button5>" = "navigate next"; # Wheel Down -> Next Page
        "<C-Button4>" = "zoom in"; # Ctrl + Wheel Up -> Zoom In
        "<C-Button5>" = "zoom out"; # Ctrl + Wheel Down -> Zoom Out
        "r" = "reload";
        "i" = "recolor"; # Toggle Dark Mode
      };
    };

    # =========================================================
    # 2. SIOYEK
    # Best for: Research papers (Smart Jumps, Portals)
    # =========================================================
    programs.sioyek = {
      enable = true;

      # prefs_user.config
      config = {
        "should_launch_new_window" = "1";

        # --- Theming ---
        # We set the custom colors, then run the toggle command on startup
        "custom_background_color" = colors.background;
        "custom_text_color" = colors.foreground;
        "startup_commands" = ["toggle_custom_color"];

        # Visuals
        "ui_font" = "JetBrainsMono Nerd Font";
        "status_bar_color" = colors.backgroundAlt;
        "status_bar_text_color" = colors.foreground;
      };

      # NOTE: We do NOT use 'programs.sioyek.bindings' here.
      # Nix attribute sets do not allow duplicate keys (e.g. mapping BOTH
      # <WheelDown> and 'J' to "next_page").
      # We define keys manually in xdg.configFile below.
    };

    # Manual Sioyek Key Definitions (keys_user.config)
    xdg.configFile."sioyek/keys_user.config".text = ''
      # --- SCROLLING LOGIC ---
      # Unbind standard scroll to prevent "smooth" scrolling
      # Bind Wheel directly to page turns
      next_page <WheelDown>
      previous_page <WheelUp>

      # --- ZOOM LOGIC ---
      # Ctrl + Wheel to zoom
      zoom_in <C-WheelUp>
      zoom_out <C-WheelDown>

      # --- KEYBOARD LOGIC ---
      # Standard Vim Bindings (Force J/K to jump pages, not scroll pixels)
      next_page J
      previous_page K
      screen_down d
      screen_up u
    '';

    # =========================================================
    # 3. OKULAR
    # Best for: Forms, Annotations, Traditional GUI
    # =========================================================
    # Visuals are handled automatically by your qt-theme.nix module.
    home.packages = with pkgs; [
      kdePackages.okular
      # Optional: PostScript support for Okular
      ghostscript
    ];
  };
}
