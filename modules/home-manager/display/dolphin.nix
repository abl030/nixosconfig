{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.dolphin;

  # 1. Fetch the Dracula GTK Theme (which contains the Kvantum theme)
  draculaThemeSource = pkgs.fetchFromGitHub {
    owner = "dracula";
    repo = "gtk";
    rev = "master"; # Using master to get the latest
    sha256 = "sha256-eT0j//ALSqyhHMOBqTYtr9z/erov8IKHDd697vybMAo="; # <--- RUN ONCE, COPY ERROR HASH, REPLACE THIS
  };
in {
  options.homelab.dolphin = {
    enable = mkEnableOption "Enable Dolphin File Manager";
  };

  config = mkIf cfg.enable {
    # 2. Configure Qt to use Kvantum
    qt = {
      enable = true;
      style.name = "kvantum";
      # platformTheme.name = "gtk"; # Optional: try enabling this if fonts look wrong later
    };

    # 3. Configure Kvantum
    # The Kvantum theme is usually located in the 'kde/kvantum' folder of the repo
    xdg.configFile = {
      "Kvantum/Dracula".source = "${draculaThemeSource}/kde/kvantum/Dracula-purple";
      # Note: The folder name inside might be 'Dracula-purple' or just 'Dracula'.
      # If the build fails saying "path does not exist", check the repo structure.

      "Kvantum/kvantum.kvconfig".text = ''
        [General]
        theme=Dracula
      '';
    };

    # 4. Packages
    home.packages = with pkgs; [
      kdePackages.dolphin
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kio-admin
      kdePackages.qtstyleplugin-kvantum
      pkgs.libsForQt5.qtstyleplugin-kvantum
      kdePackages.breeze-icons
      kdePackages.kdegraphics-thumbnailers
      kdePackages.ffmpegthumbs
      kdePackages.qtimageformats
      kdePackages.qtsvg
      shared-mime-info
    ];

    home.sessionVariables = {
      XDG_CURRENT_DESKTOP = "Hyprland";
      XDG_SESSION_TYPE = "wayland";
    };
  };
}
