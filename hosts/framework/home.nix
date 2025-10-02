{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ./framework_home_specific.nix
    # Framework specifici gnome overrides
    # ../../home/display_managers/dconf_framework.nix
  ];
}
