{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "testvm";
  home.homeDirectory = "/home/testvm";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "24.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    pkgs.tmux
    # # It is sometimes useful to fine-tune packages, for example, by applying
    pkgs.git
    # # overrides. You can do that directly here, just don't forget the
    pkgs.gh
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    "test".source = ./test;
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
  #  /etc/profiles/per-user/testvm/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.zsh = {
    enable = true;
    oh-my-zsh = {
      enable = true;
      plugins = [
        "tmux"
        "common-aliases"
        "copypath"
        "copyfile"
        "ubuntu"
        "git"
        "history"
        "history-substring-search"
        # "autoupdate" # https://github.com/tamcore/autoupdate-oh-my-zsh-plugins
        # "zsh-syntax-highlighting" # https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/INSTALL.md
        # "zsh-autosuggestions"
        # "zsh-autocomplete" # https://gist.github.com/n1snt/454b879b8f0b7995740ae04c5fb5b7df
        "rust"
        "pyenv"
      ];
      theme = "robbyrussell"; # You can change this if you'd like a different theme
    };
    zplug = {
      enable = true;
      plugins = [
        { name = "tamcore/autoupdate-oh-my-zsh-plugins"; }
        { name = "zsh-users/zsh-syntax-highlighting"; }
        { name = "marlonrichert/zsh-autocomplete"; }
        { name = "zsh-users/zsh-autosuggestions"; }
      ];
    };
    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
    ];
    # initExtra = ''
    #   [[ ! -f ${./.p10k.zsh} ]] || source ${./.p10k.zsh}
    # '';
  };

  programs.git = {
    # enable = true;
    userName = "abl030";
    userEmail = "abl030@g.m.a.i.l";


  };
}
