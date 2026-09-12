{pkgs, ...}: {
  # GNOME ships gcr-ssh-agent as the SSH agent, which caches an unlocked key
  # for the whole login session (no TTL). Replace it with our plain 1h-TTL
  # ssh-agent. Pairs with `services.gnome.gcr-ssh-agent.enable = false` in each
  # GNOME host's system config so the plain agent is the only SSH agent.
  homelab.ssh.localAgent.enable = true;

  home.packages = [
    pkgs.gnome-tweaks
    pkgs.gnomeExtensions.dash-to-panel
    pkgs.gnomeExtensions.bluetooth-quick-connect
    pkgs.gnomeExtensions.blur-my-shell
    pkgs.gnomeExtensions.tray-icons-reloaded
    pkgs.gnomeExtensions.user-themes
    pkgs.gnomeExtensions.freon
    pkgs.gnomeExtensions.just-perfection
    pkgs.gnomeExtensions.caffeine
    pkgs.gnomeExtensions.grand-theft-focus
    pkgs.dconf2nix
    pkgs.kdePackages.qtwayland
    pkgs.gnomeExtensions.paperwm
    pkgs.gnomeExtensions.allow-locked-remote-desktop
    pkgs.gnomeExtensions.system-monitor
    # AATWS replaces the stock Alt+Tab/Super+Tab popups. Chosen because Just
    # Perfection's "Alt Tab Window Preview Size" has been a no-op since GNOME 45
    # made altTab.js's WINDOW_PREVIEW_SIZE a read-only module const (upstream
    # issue jrahmatzadeh/just-perfection#240, open since 2024-02).
    pkgs.gnomeExtensions.advanced-alttab-window-switcher
  ];

  # Alt+Tab switches *windows*, not grouped applications, so several Firefox
  # windows are each their own Alt+Tab entry (no mouse trip into the app
  # drop-down). Super+Tab keeps the grouped application switcher. The per-host
  # ./gnome_configs/*.nix dconf dumps are dormant (import below is commented
  # out), so this is the live source of truth for these bindings.
  dconf.settings."org/gnome/desktop/wm/keybindings" = {
    switch-windows = ["<Alt>Tab"];
    switch-windows-backward = ["<Shift><Alt>Tab"];
    switch-applications = ["<Super>Tab"];
    switch-applications-backward = ["<Shift><Super>Tab"];
  };

  # AATWS window-switcher preview size (stock GNOME is a fixed 128px). Tune
  # live with `gsettings set org.gnome.shell.extensions.advanced-alt-tab-window-switcher
  # win-switcher-popup-preview-size N` or the extension's prefs dialog.
  dconf.settings."org/gnome/shell/extensions/advanced-alt-tab-window-switcher" = {
    win-switcher-popup-preview-size = 256;
  };

  imports = [
    # ./gnome_configs/${hostname}.nix
  ];
}
