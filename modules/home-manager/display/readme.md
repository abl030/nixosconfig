## Qt6 & Dolphin Theming in Hyprland (The Final Working Architecture)

### The Problem

1. **No Theming:** Under Hyprland, Dolphin ignored Home Manager Qt/GTK settings and came up as raw Breeze.
2. **“Stuck on Breeze” Bug:** With `QT_QPA_PLATFORMTHEME=qt6ct`, Dolphin either:
   - Ignored `qt6ct`’s palette, **and**
   - Only partially respected `kdeglobals`, often falling back to Breeze/BreezeLight/Breeze Darker.

In short: **qt6ct as the platform theme is not enough** for Dolphin + Qt6 + KDE Frameworks outside a full Plasma session.

---

### The Working Solution: a Fake Mini-KDE Stack

We fixed it by synthesizing a minimal KDE environment in three layers:

#### 1. System Layer (NixOS): use the KDE platform theme

Define Qt/KDE environment at the **system level**, not in Home Manager:

```nix
# modules/nixos/services/display/hyprland.nix (excerpt)
environment.sessionVariables = {
  # Use KDE's platform theme plugin instead of qt6ct
  QT_QPA_PLATFORMTHEME = "KDE";

  # Required so Dolphin / KIO / KService find service menus & MIME stuff
  XDG_MENU_PREFIX = "plasma-";
};
````

**Key learning:**
`QT_QPA_PLATFORMTHEME=qt6ct` keeps Dolphin visually stuck on Breeze, regardless of what you do in `kdeglobals`. Using the KDE platform theme unlocks proper **KColorScheme** handling.

---

#### 2. Theme Layer (Home Manager): Single Source of Truth → `.colors` + `kdeglobals`

We treat `homelab.theme.colors` as the **only palette source** and derive everything else from it.

1. Convert the hex colors to RGB (`44,42,36` style).
2. Generate a KDE color scheme:

```nix
# ~/.local/share/color-schemes/NixOSTheme.colors
xdg.dataFile."color-schemes/NixOSTheme.colors".text = ''
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
```

3. Point global KDE settings at this scheme and set icons:

```nix
# ~/.config/kdeglobals
xdg.configFile."kdeglobals".text = ''
  [General]
  ColorScheme=NixOSTheme
  Name=NixOSTheme

  [Icons]
  Theme=breeze-dark
'';
```

**Key learnings:**

* KDE will **log an explicit error** if the scheme name in `kdeglobals` doesn’t match an actual `.colors` file:

  > `Could not find color scheme "NixOSTheme" falling back to BreezeLight`
* Once `NixOSTheme.colors` exists and matches `ColorScheme=NixOSTheme`, the palette is loaded correctly.

---

#### 3. Application Layer: Tell Dolphin to use our scheme

Modern Dolphin also reads `~/.config/dolphinrc` for its own color scheme selection.

```nix
# ~/.config/dolphinrc
xdg.configFile."dolphinrc".text = ''
  [UiSettings]
  ColorScheme=NixOSTheme

  [Icons]
  Theme=breeze-dark
'';
```

**Key learning:**
Without `ColorScheme=NixOSTheme` in `dolphinrc`, Dolphin can happily load our `.colors` file but still choose Breeze/Breeze Darker internally.

---

### Lessons Learned (for Future Me / Future ChatGPT)

1. **Don’t use `QT_QPA_PLATFORMTHEME=qt6ct` for Dolphin theming** on Qt6: it’s fine for generic Qt apps, but Dolphin ignores the custom palette and clings to Breeze.
2. **KDE theming is driven by KColorScheme**, which expects:

   * A real `.colors` file under `~/.local/share/color-schemes/`,
   * Matching `ColorScheme=` keys in `kdeglobals` and app-specific `*rc` files (e.g. `dolphinrc`).
3. **System vs Home Manager env vars:**

   * System-level `environment.sessionVariables` (NixOS) are the only reliable way to get Qt/KDE env into a Hyprland session started via SDDM.
   * `home.sessionVariables` is too late for the compositor → child apps miss critical vars.
4. **Debug traps:**

   * Temporary scripts that *create then delete* `.colors` files cause confusing “fallback to Breeze” behaviour later, once the theme is managed declaratively by Home Manager.
   * Qt’s QPA logs may say the platform theme is “generic” even when `QT_QPA_PLATFORMTHEME=KDE`, but as long as KColorScheme sees our `.colors` + `dolphinrc`, Dolphin will use the right palette.

---

### Minimal Nix Summary (Copy-Paste Reference)

```nix
# NixOS (Hyprland system module, excerpt)
environment.sessionVariables = {
  QT_QPA_PLATFORMTHEME = "KDE";
  XDG_MENU_PREFIX = "plasma-";
};

# Home Manager (Dolphin module, excerpts)
xdg.dataFile."color-schemes/NixOSTheme.colors".text = schemeText; # from homelab.theme.colors

xdg.configFile."kdeglobals".text = ''
  [General]
  ColorScheme=NixOSTheme
  Name=NixOSTheme
  [Icons]
  Theme=breeze-dark
'';

xdg.configFile."dolphinrc".text = ''
  [UiSettings]
  ColorScheme=NixOSTheme
  [Icons]
  Theme=breeze-dark
'';
```

---

### Debug Script (Quick Check for “Why is Dolphin Blue Again?”)

Save this as `/tmp/dolphin-theme-debug.sh` (or similar) and run it from a **Hyprland terminal**:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "== Qt / KDE env in this session =="
echo "QT_QPA_PLATFORMTHEME=${QT_QPA_PLATFORMTHEME:-[unset]}"
echo "XDG_MENU_PREFIX=${XDG_MENU_PREFIX:-[unset]}"
echo

echo "== Color scheme files =="
ls -l "$HOME/.local/share/color-schemes/NixOSTheme.colors" || echo "NixOSTheme.colors missing"
echo

echo "== ColorScheme references =="
rg -n "ColorScheme" \
  "$HOME/.config/kdeglobals" \
  "$HOME/.config/dolphinrc" \
  "$HOME/.local/share/color-schemes/NixOSTheme.colors" || true
echo

echo "== Sample roles from NixOSTheme.colors =="
rg -n "BackgroundNormal|ForegroundNormal|Selection" \
  "$HOME/.local/share/color-schemes/NixOSTheme.colors" || true
echo

echo "== Launching Dolphin with basic theme logging (close it to end) =="
QT_LOGGING_RULES="qt.qpa.theme=true" dolphin 2>&1 | head -n 40
```

Run:

```bash
chmod +x /tmp/dolphin-theme-debug.sh
/tmp/dolphin-theme-debug.sh
```

If `ColorScheme=NixOSTheme` appears everywhere and `NixOSTheme.colors` exists, Dolphin should be using your SSOT palette. If not, the script output will point at the missing step.

