{pkgs, ...}: let
  # `fix-displays`: re-apply the golden GNOME monitor layout via gdctl.
  #
  # WHY: exclusive-fullscreen games (OpenMW) force a mode switch; on exit
  # mutter drops to a side-by-side fallback and does NOT re-apply the saved
  # ~/.config/monitors.xml. This pushes the layout back over the live
  # org.gnome.Mutter.DisplayConfig D-Bus API.
  #
  # NOTE: deliberately NO `-P`. monitors.xml is Home-Manager-managed (golden
  # layout at hosts/epi/monitors.xml, symlinked in), so persistence across
  # logout/login already comes from HM. `gdctl -P` rewrites monitors.xml as a
  # real file and clobbers the HM symlink — which broke nixos-upgrade
  # activation on 2026-06-21 (hm refused to overwrite the stray file). The
  # live D-Bus apply alone is all this command needs.
  #
  # Layout mirrors hosts/epi/monitors.xml:
  #   DP-3    2560x1440  primary, centre   (x 1080, y 187)
  #   HDMI-2  1920x1080  portrait (rot right = transform 270), left (x 0, y 0)
  #   HDMI-3  1920x1080  right             (x 3640, y 351)
  # gdctl ships with mutter; pkgs.mutter matches the running GNOME session.
  fix-displays = pkgs.writeShellScriptBin "fix-displays" ''
    exec ${pkgs.mutter}/bin/gdctl set \
      -L -x 1080 -y 187 -p    -M DP-3   -m 2560x1440@59.951 \
      -L -x 0    -y 0   -t 270 -M HDMI-2 -m 1920x1080@74.973 \
      -L -x 3640 -y 351       -M HDMI-3 -m 1920x1080@60.000
  '';
in {
  home.packages = [
    fix-displays
    pkgs.kdePackages.dolphin
    # These are our thumbnailers. QT5 because we using LXQT.
    # Use the KDE ones is you are using KDE elsewhere
    pkgs.kdePackages.kdegraphics-thumbnailers
    pkgs.kdePackages.kio-extras
    pkgs.kdePackages.ffmpegthumbs
    pkgs.kdePackages.dolphin-plugins
    pkgs.kdePackages.qtwayland
    pkgs.kdePackages.qtsvg
    pkgs.libsForQt5.qt5ct
    pkgs.zathura
    # pkgs.ganttproject-bin
    # pkgs.ghostty
    # pkgs.retroarchFull
    pkgs.winePackages.full
  ];
  imports = [
    # ../../home/zsh/zsh2.nix
  ];
}
