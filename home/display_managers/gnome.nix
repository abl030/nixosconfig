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
    pkgs.dracula-theme
    pkgs.gnomeExtensions.freon
    pkgs.gnomeExtensions.just-perfection
    pkgs.gnomeExtensions.caffeine
    pkgs.gnomeExtensions.grand-theft-focus
    pkgs.dconf2nix
    pkgs.kdePackages.qtwayland
    pkgs.gnomeExtensions.paperwm
    pkgs.gnomeExtensions.allow-locked-remote-desktop
    pkgs.gnomeExtensions.system-monitor
  ];

  imports = [
    # ./gnome_configs/${hostname}.nix
  ];
}
