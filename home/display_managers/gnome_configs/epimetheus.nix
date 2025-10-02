{lib, ...}:
with lib.hm.gvariant; {
  dconf.settings = {
    "org/gnome/Console" = {
      last-window-maximised = true;
      last-window-size = mkTuple [492 384];
    };

    "org/gnome/Extensions" = {
      window-maximized = true;
    };

    "org/gnome/desktop/app-folders/folders/Utilities" = {
      apps = ["gnome-abrt.desktop" "gnome-system-log.desktop" "nm-connection-editor.desktop" "org.gnome.baobab.desktop" "org.gnome.Connections.desktop" "org.gnome.DejaDup.desktop" "org.gnome.Dictionary.desktop" "org.gnome.DiskUtility.desktop" "org.gnome.Evince.desktop" "org.gnome.FileRoller.desktop" "org.gnome.fonts.desktop" "org.gnome.Loupe.desktop" "org.gnome.seahorse.Application.desktop" "org.gnome.tweaks.desktop" "org.gnome.Usage.desktop" "vinagre.desktop"];
      categories = ["X-GNOME-Utilities"];
      name = "X-GNOME-Utilities.directory";
      translate = true;
    };

    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      cursor-size = 24;
      cursor-theme = "Adwaita";
      enable-animations = true;
      font-name = "SauceCodePro Nerd Font Medium 10";
      gtk-theme = "Adwaita";
      icon-theme = "Adwaita";
      scaling-factor = mkUint32 1;
      show-battery-percentage = true;
      text-scaling-factor = 1.4;
      toolbar-style = "text";
      toolkit-accessibility = false;
    };

    "org/gnome/desktop/peripherals/keyboard" = {
      numlock-state = false;
    };

    "org/gnome/desktop/peripherals/mouse" = {
      accel-profile = "flat";
    };

    "org/gnome/desktop/peripherals/touchpad" = {
      two-finger-scrolling-enabled = true;
    };

    "org/gnome/desktop/session" = {
      idle-delay = mkUint32 900;
    };

    "org/gnome/desktop/sound" = {
      event-sounds = false;
      theme-name = "__custom";
    };

    "org/gnome/desktop/wm/keybindings" = {
      maximize = ["<Super>Up"];
      move-to-monitor-down = ["<Super><Shift>Down"];
      move-to-monitor-left = ["<Super><Shift>Left"];
      move-to-monitor-right = ["<Super><Shift>Right"];
      move-to-monitor-up = ["<Super><Shift>Up"];
      move-to-workspace-down = ["<Control><Shift><Alt>Down"];
      move-to-workspace-left = ["<Super><Shift>Page_Up" "<Super><Shift><Alt>Left" "<Control><Shift><Alt>Left"];
      move-to-workspace-right = ["<Super><Shift>Page_Down" "<Super><Shift><Alt>Right" "<Control><Shift><Alt>Right"];
      move-to-workspace-up = ["<Control><Shift><Alt>Up"];
      switch-applications = ["<Super>Tab" "<Alt>Tab"];
      switch-applications-backward = ["<Shift><Super>Tab" "<Shift><Alt>Tab"];
      switch-group = ["<Super>Above_Tab" "<Alt>Above_Tab"];
      switch-group-backward = ["<Shift><Super>Above_Tab" "<Shift><Alt>Above_Tab"];
      switch-panels = ["<Control><Alt>Tab"];
      switch-panels-backward = ["<Shift><Control><Alt>Tab"];
      switch-to-workspace-1 = ["<Super>Home"];
      switch-to-workspace-last = ["<Super>End"];
      switch-to-workspace-left = ["<Super>Page_Up" "<Super><Alt>Left" "<Control><Alt>Left"];
      switch-to-workspace-right = ["<Super>Page_Down" "<Super><Alt>Right" "<Control><Alt>Right"];
      unmaximize = ["<Super>Down" "<Alt>F5"];
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = "appmenu:minimize,maximize,close";
    };

    "org/gnome/epiphany" = {
      ask-for-default = false;
    };

    "org/gnome/epiphany/state" = {
      is-maximized = true;
      window-size = mkTuple [1128 720];
    };

    "org/gnome/settings-daemon/plugins/power" = {
      power-button-action = "hibernate";
      power-saver-profile-on-low-battery = false;
      sleep-inactive-ac-timeout = 3600;
      sleep-inactive-ac-type = "suspend";
      sleep-inactive-battery-type = "suspend";
    };

    "org/gnome/shell" = {
      command-history = ["r"];
      enabled-extensions = ["drive-menu@gnome-shell-extensions.gcampax.github.com" "blur-my-shell@aunetx" "dash-to-panel@jderose9.github.com" "system-monitor@gnome-shell-extensions.gcampax.github.com" "windowsNavigator@gnome-shell-extensions.gcampax.github.com" "user-theme@gnome-shell-extensions.gcampax.github.com" "just-perfection-desktop@just-perfection" "grand-theft-focus@zalckos.github.com" "caffeine@patapon.info" "allowlockedremotedesktop@kamens.us"];
      favorite-apps = ["org.kde.dolphin.desktop" "firefox.desktop" "google-chrome.desktop"];
    };

    "org/gnome/shell/extensions/blur-my-shell" = {
      settings-version = 2;
    };

    "org/gnome/shell/extensions/blur-my-shell/appfolder" = {
      brightness = 0.6;
      sigma = 30;
    };

    "org/gnome/shell/extensions/blur-my-shell/dash-to-dock" = {
      blur = true;
      brightness = 0.6;
      sigma = 30;
      static-blur = true;
      style-dash-to-dock = 0;
    };

    "org/gnome/shell/extensions/blur-my-shell/panel" = {
      brightness = 0.6;
      sigma = 30;
    };

    "org/gnome/shell/extensions/blur-my-shell/window-list" = {
      brightness = 0.6;
      sigma = 30;
    };

    "org/gnome/shell/extensions/caffeine" = {
      indicator-position-max = 2;
      show-indicator = "only-active";
    };

    "org/gnome/shell/extensions/dash-to-panel" = {
      appicon-margin = 8;
      appicon-padding = 4;
      available-monitors = [0];
      dot-position = "BOTTOM";
      group-apps = true;
      hotkeys-overlay-combo = "TEMPORARILY";
      isolate-monitors = true;
      leftbox-padding = -1;
      panel-anchors = ''
        {"0":"MIDDLE","1":"MIDDLE"}
      '';
      panel-element-positions = ''
        {"0":[{"element":"showAppsButton","visible":false,"position":"centered"},{"element":"activitiesButton","visible":true,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedTL"},{"element":"dateMenu","visible":true,"position":"stackedTL"},{"element":"systemMenu","visible":true,"position":"stackedTL"},{"element":"desktopButton","visible":true,"position":"stackedTL"}],"1":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":false,"position":"stackedTL"},{"element":"dateMenu","visible":false,"position":"stackedTL"},{"element":"systemMenu","visible":false,"position":"centerMonitor"},{"element":"desktopButton","visible":false,"position":"stackedTL"}]}
      '';
      panel-element-positions-monitors-sync = false;
      panel-lengths = ''
        {"0":100,"1":100}
      '';
      panel-sizes = ''
        {"0":64,"1":48}
      '';
      primary-monitor = 0;
      status-icon-padding = -1;
      tray-padding = -1;
      window-preview-title-position = "TOP";
    };

    "org/gnome/shell/extensions/just-perfection" = {
      dash = true;
      dash-app-running = true;
      dash-separator = true;
      events-button = false;
      weather = false;
      workspace-wrap-around = true;
      world-clock = false;
    };

    "org/gnome/shell/extensions/paperwm" = {
      last-used-display-server = "Wayland";
      open-window-position = 1;
      restore-attach-modal-dialogs = "false";
      restore-edge-tiling = "false";
      restore-keybinds = ''
        {}\n
      '';
      restore-workspaces-only-on-primary = "false";
    };

    "org/gnome/shell/extensions/system-monitor" = {
      show-memory = false;
      show-swap = false;
    };

    "org/gnome/shell/extensions/user-theme" = {
      name = "Dracula";
    };

    "org/gnome/shell/world-clocks" = {
      locations = [];
    };

    "org/gnome/tweaks" = {
      show-extensions-notice = false;
    };

    "org/gtk/settings/file-chooser" = {
      date-format = "regular";
      location-mode = "path-bar";
      show-hidden = false;
      show-size-column = true;
      show-type-column = true;
      sidebar-width = 148;
      sort-column = "name";
      sort-directories-first = false;
      sort-order = "descending";
      type-format = "category";
      window-position = mkTuple [26 23];
      window-size = mkTuple [740 534];
    };
  };
}
