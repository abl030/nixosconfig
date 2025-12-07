## Qt6 & Dolphin Theming in Hyprland (The Complete Fix)

**The Problem:**
1.  **No Theming:** Dolphin ignores Home Manager GTK/Qt settings by default in Hyprland, reverting to a raw/ugly fallback style.
2.  **Broken Dark Mode:** Even when theming is enabled, Dolphin displays a persistent white background in the file view because it cannot query running KDE services for color roles.

**The Solution: A 3-Layer "Fake" KDE Environment**
Since we don't have KDE Plasma running, we must manually synthesize the environment Qt6 expects.

### 1. The "On" Switch (Environment Variables)
We must explicitly tell Qt *not* to look for Plasma, but to use the **qt6ct** configuration tool instead.
*   `QT_QPA_PLATFORMTHEME = "qt6ct"` -> **Critical:** Without this, Qt ignores all config files.
*   `QT_QPA_PLATFORM = "wayland"` -> Ensures native rendering (crisper text).

### 2. The Configuration (Automated `qt6ct.conf`)
`qt6ct` usually requires a manual GUI setup. We bypass this by generating `~/.config/qt6ct/qt6ct.conf` declaratively.
*   **Action:** We write a config file that hardcodes `style=Breeze` and `icon_theme=breeze-dark`.
*   **Result:** Dolphin knows *what* theme to load immediately on launch.

### 3. The Patch (Synthesized `kdeglobals`)
The "White Background" bug happens because Dolphin reads the theme but fails to apply the `BackgroundNormal` role without D-Bus.
*   **Action:** We read the official `BreezeDark.colors` from the Nix store, append a specific override (`BackgroundNormal=30,31,33`), and write it to `~/.config/kdeglobals`.
*   **Result:** We force the correct RGB values into the exact path Dolphin checks when it falls back to file-based config.

### Summary Snippet
```nix
# 1. Enable the Engine
home.sessionVariables.QT_QPA_PLATFORMTHEME = "qt6ct";

# 2. Configure the Engine (Select Breeze)
xdg.configFile."qt6ct/qt6ct.conf".text = ''... style=Breeze ...'';

# 3. Patch the Colors (Fix White Background)
xdg.configFile."kdeglobals".text = 
  (builtins.readFile "${pkgs.kdePackages.breeze}/.../BreezeDark.colors") 
  + "[Colors:View]\nBackgroundNormal=30,31,33";
```
