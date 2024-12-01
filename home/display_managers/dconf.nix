# Generated via dconf2nix: https://github.com/gvolpe/dconf2nix
{ lib, ... }:

with lib.hm.gvariant;

{
  dconf.settings = {
    "org/gnome/Console" = {
      last-window-maximised = true;
      last-window-size = mkTuple [ 652 480 ];
    };

    "org/gnome/Extensions" = {
      window-maximized = true;
    };

    "org/gnome/Geary" = {
      migrated-config = true;
    };

    "org/gnome/clocks/state/window" = {
      maximized = false;
      panel-id = "timer";
      size = mkTuple [ 870 690 ];
    };

    "org/gnome/control-center" = {
      last-panel = "background";
      window-state = mkTuple [ 980 640 true ];
    };

    "org/gnome/desktop/a11y/applications" = {
      screen-reader-enabled = false;
    };

    "org/gnome/desktop/app-folders" = {
      folder-children = [ "Utilities" "YaST" "Pardus" ];
    };

    "org/gnome/desktop/app-folders/folders/Pardus" = {
      categories = [ "X-Pardus-Apps" ];
      name = "X-Pardus-Apps.directory";
      translate = true;
    };

    "org/gnome/desktop/app-folders/folders/Utilities" = {
      apps = [ "gnome-abrt.desktop" "gnome-system-log.desktop" "nm-connection-editor.desktop" "org.gnome.baobab.desktop" "org.gnome.Connections.desktop" "org.gnome.DejaDup.desktop" "org.gnome.Dictionary.desktop" "org.gnome.DiskUtility.desktop" "org.gnome.Evince.desktop" "org.gnome.FileRoller.desktop" "org.gnome.fonts.desktop" "org.gnome.Loupe.desktop" "org.gnome.seahorse.Application.desktop" "org.gnome.tweaks.desktop" "org.gnome.Usage.desktop" "vinagre.desktop" ];
      categories = [ "X-GNOME-Utilities" ];
      name = "X-GNOME-Utilities.directory";
      translate = true;
    };

    "org/gnome/desktop/app-folders/folders/YaST" = {
      categories = [ "X-SuSE-YaST" ];
      name = "suse-yast.directory";
      translate = true;
    };

    "org/gnome/desktop/input-sources" = {
      sources = [ (mkTuple [ "xkb" "us" ]) ];
      xkb-options = [ "terminate:ctrl_alt_bksp" ];
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
      text-scaling-factor = 1.0;
      toolbar-style = "text";
    };

    "org/gnome/desktop/notifications" = {
      application-children = [ "org-gnome-console" "firefox" "gnome-power-panel" "org-gnome-geary" "plexamp" "org-gnome-settings" "org-gnome-nautilus" ];
      show-banners = false;
    };

    "org/gnome/desktop/notifications/application/firefox" = {
      application-id = "firefox.desktop";
    };

    "org/gnome/desktop/notifications/application/gnome-power-panel" = {
      application-id = "gnome-power-panel.desktop";
    };

    "org/gnome/desktop/notifications/application/org-gnome-console" = {
      application-id = "org.gnome.Console.desktop";
    };

    "org/gnome/desktop/notifications/application/org-gnome-geary" = {
      application-id = "org.gnome.Geary.desktop";
    };

    "org/gnome/desktop/notifications/application/org-gnome-nautilus" = {
      application-id = "org.gnome.Nautilus.desktop";
    };

    "org/gnome/desktop/notifications/application/org-gnome-settings" = {
      application-id = "org.gnome.Settings.desktop";
    };

    "org/gnome/desktop/notifications/application/plexamp" = {
      application-id = "plexamp.desktop";
    };

    "org/gnome/desktop/peripherals/keyboard" = {
      numlock-state = true;
    };

    "org/gnome/desktop/peripherals/touchpad" = {
      two-finger-scrolling-enabled = true;
    };

    "org/gnome/desktop/search-providers" = {
      sort-order = [ "org.gnome.Settings.desktop" "org.gnome.Contacts.desktop" "org.gnome.Nautilus.desktop" ];
    };

    "org/gnome/desktop/sound" = {
      theme-name = "ocean";
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = ":minimize,maximize,close";
    };

    "org/gnome/epiphany" = {
      ask-for-default = false;
    };

    "org/gnome/epiphany/state" = {
      is-maximized = false;
      window-size = mkTuple [ 1024 768 ];
    };

    "org/gnome/evolution-data-server" = {
      migrated = true;
    };

    "org/gnome/gnome-system-monitor" = {
      current-tab = "resources";
      maximized = true;
      show-dependencies = false;
      show-whose-processes = "user";
    };

    "org/gnome/gnome-system-monitor/proctree" = {
      col-26-visible = false;
      col-26-width = 0;
      columns-order = [ 0 12 1 2 3 4 6 7 8 9 10 11 13 14 15 16 17 18 19 20 21 22 23 24 25 26 ];
      sort-col = 24;
      sort-order = 1;
    };

    "org/gnome/nautilus/list-view" = {
      use-tree-view = true;
    };

    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "list-view";
      migrated-gtk-settings = true;
      recursive-search = "always";
      search-filter-time-type = "last_modified";
      show-directory-item-counts = "always";
      show-image-thumbnails = "always";
    };

    "org/gnome/nautilus/window-state" = {
      initial-size = mkTuple [ 890 550 ];
      maximized = true;
    };

    "org/gnome/settings-daemon/plugins/color" = {
      night-light-schedule-automatic = false;
    };

    "org/gnome/shell" = {
      command-history = [ "r" ];
      disabled-extensions = [ "apps-menu@gnome-shell-extensions.gcampax.github.com" "bluetooth-quick-connect@bjarosze.gmail.com" "trayIconsReloaded@selfmade.pl" "window-list@gnome-shell-extensions.gcampax.github.com" "workspace-indicator@gnome-shell-extensions.gcampax.github.com" "native-window-placement@gnome-shell-extensions.gcampax.github.com" "freon@UshakovVasilii_Github.yahoo.com" ];
      enabled-extensions = [ "drive-menu@gnome-shell-extensions.gcampax.github.com" "blur-my-shell@aunetx" "dash-to-panel@jderose9.github.com" "system-monitor@gnome-shell-extensions.gcampax.github.com" "windowsNavigator@gnome-shell-extensions.gcampax.github.com" "user-theme@gnome-shell-extensions.gcampax.github.com" "just-perfection-desktop@just-perfection" "grand-theft-focus@zalckos.github.com" "caffeine@patapon.info" ];
      favorite-apps = [ "org.gnome.Nautilus.desktop" "firefox.desktop" ];
      welcome-dialog-last-shown-version = "46.2";
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
      indicator-position-max = 1;
      show-indicator = "only-active";
      toggle-state = false;
    };

    "org/gnome/shell/extensions/dash-to-panel" = {
#      animate-appicon-hover-animation-extent = {
#        RIPPLE = 4;
#        PLANK = 4;
#        SIMPLE = 1;
#      };
      appicon-margin = 8;
      appicon-padding = 4;
      available-monitors = [ 0 1 ];
      dot-position = "BOTTOM";
      group-apps = true;
      hotkeys-overlay-combo = "TEMPORARILY";
      isolate-monitors = true;
      leftbox-padding = -1;
      panel-anchors = ''
        {"0":"MIDDLE","1":"MIDDLE"}
      '';
      panel-element-positions = ''
        {"0":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":true,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedTL"},{"element":"dateMenu","visible":true,"position":"stackedTL"},{"element":"systemMenu","visible":true,"position":"stackedTL"},{"element":"desktopButton","visible":true,"position":"stackedTL"}],"1":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":false,"position":"stackedTL"},{"element":"dateMenu","visible":false,"position":"stackedTL"},{"element":"systemMenu","visible":false,"position":"centerMonitor"},{"element":"desktopButton","visible":false,"position":"stackedTL"}]}
      '';
      panel-element-positions-monitors-sync = false;
      panel-lengths = ''
        {"0":100,"1":100}
      '';
      panel-sizes = ''
        {"0":48,"1":48}
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

    "org/gtk/gtk4/settings/color-chooser" = {
      selected-color = mkTuple [ true 0.207843 0.517647 0.894118 1.0 ];
    };

    "org/gtk/gtk4/settings/file-chooser" = {
      date-format = "regular";
      location-mode = "path-bar";
      show-hidden = false;
      sidebar-width = 140;
      sort-column = "name";
      sort-directories-first = true;
      sort-order = "ascending";
      type-format = "category";
      view-type = "list";
      window-size = mkTuple [ 859 366 ];
    };

    "org/gtk/settings/file-chooser" = {
      date-format = "regular";
      location-mode = "path-bar";
      show-hidden = false;
      show-size-column = true;
      show-type-column = true;
      sidebar-width = 157;
      sort-column = "name";
      sort-directories-first = false;
      sort-order = "descending";
      type-format = "category";
      window-position = mkTuple [ 2315 127 ];
      window-size = mkTuple [ 1130 826 ];
    };

    "org/virt-manager/virt-manager" = {
      manager-window-height = 550;
      manager-window-width = 550;
    };

    "org/virt-manager/virt-manager/confirm" = {
      forcepoweroff = true;
      removedev = true;
    };

    "org/virt-manager/virt-manager/details" = {
      show-toolbar = true;
    };

    "org/virt-manager/virt-manager/paths" = {
      image-default = "/home/abl030/Downloads/Challenge VM 1/NetEvolveServer1";
    };

    "org/virt-manager/virt-manager/vmlist-fields" = {
      disk-usage = false;
      network-traffic = false;
    };

    "org/virt-manager/virt-manager/vms/072d61a08ebf4316a25903b4a54825ad" = {
      autoconnect = 1;
      scaling = 1;
      vm-window-size = mkTuple [ 1024 845 ];
    };

    "org/virt-manager/virt-manager/vms/2b59f31bd3fd443ca89a695c9081c829" = {
      autoconnect = 1;
      scaling = 1;
      vm-window-size = mkTuple [ 1024 845 ];
    };

    "org/virt-manager/virt-manager/vms/342d33e7f2f942e994c68faf57561451" = {
      autoconnect = 1;
      scaling = 1;
      vm-window-size = mkTuple [ 1920 1012 ];
    };

    "org/virt-manager/virt-manager/vms/34bf7c1df9d44e3ea1633700a54acb13" = {
      autoconnect = 1;
      scaling = 1;
      vm-window-size = mkTuple [ 1024 845 ];
    };

    "org/virt-manager/virt-manager/vms/da187020399d409d9c4bec3a2a40d0cc" = {
      autoconnect = 1;
      scaling = 1;
      vm-window-size = mkTuple [ 1024 845 ];
    };

  };
}
