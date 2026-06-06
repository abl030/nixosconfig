{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ../../home/utils/desktop.nix
    ../../home/display_managers/gnome.nix
    ./framework_home_specific.nix
    ./cullen-mount.nix # on-demand sshfs to the Cullen office Z: drive via `ssh wsl`
    # Framework specifici gnome overrides
    # ../../home/display_managers/dconf_framework.nix
  ];
}
