{pkgs, ...}: {
  imports = [
    # ../../home/zsh/zsh2.nix
    # ./fish/fish.nix
    ../../home/bash/bash.nix
    ../../home/zsh/zsh2.nix
    ../../home/fish/fish.nix
    ../../home/nvim/nvim.nix
    #It doesn't make sense to use home-manager for our authorized keys file. It's weird but
    # ../secrets/sops_home.nix
    ../../home/utils/common.nix
  ];

  homelab = {
    ssh = {
      enable = true;
    };
    # claudePlugins enabled fleet-wide via modules/home-manager/profiles/base.nix
  };

  # Group all home-manager settings into a single `home` block to avoid repeated keys.
  home = {
    # Home Manager needs a bit of information about you and the paths it should
    # manage.
    username = "nixos";
    homeDirectory = "/home/nixos";
    sessionPath = [
      "/mnt/c/Users/andy.b/AppData/Local/Microsoft/WinGet/Packages/equalsraf.win32yank_Microsoft.Winget.Source_8wekyb3d8bbwe"
    ];
    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    stateVersion = "25.05"; # Please read the comment before changing.

    # The home.packages option allows you to install Nix packages into your
    # environment.
    packages = with pkgs; [
      # Build deps for episodic-memory native modules (better-sqlite3)
      nodejs
      python3
      gnumake
      gcc
    ];

    # Home Manager is pretty good at managing dotfiles. The primary way to manage
    # plain files is through 'home.file'.
    file = {
      # # Building this configuration will create a copy of 'dotfiles/screenrc' in
      # # the Nix store. Activating the configuration will then make '~/.screenrc' a
      # # symlink to the Nix store copy.
      # ".screenrc".source = dotfiles/screenrc;

      # # You can also set the file content immediately.
      # ".gradle/gradle.properties".text = ''
      #   org.gradle.console=verbose
      #   org.gradle.daemon.idletimeout=3600000
      # '';
    };

    # Home Manager can also manage your environment variables through
    # 'home.sessionVariables'. These will be explicitly sourced when using a
    # shell provided by Home Manager. If you don't want to manage your shell
    # through Home Manager then you have to manually source 'hm-session-vars.sh'
    # located at either
    #
    #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
    #
    # or
    #
    #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
    #
    # or
    #
    #  /etc/profiles/per-user/nixos/etc/profile.d/hm-session-vars.sh
    #
    sessionVariables = {
      # EDITOR = "emacs";
    };
  };

  programs = {
    # Let Home Manager install and manage itself.
    home-manager.enable = true;
  };
}
