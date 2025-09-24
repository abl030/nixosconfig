{ config, pkgs, homeDirectory, inputs, ... }:
{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  # home.username = username;
  # home.homeDirectory = homeDirectory;

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "24.05"; # Please read the comment before changing.
  #This is to lower the level of logging by NIXD in ~/.local/state/nvim/lsp.log
  #This was used during the saga to get home_manager lsp completion through nixd. 
  #It can probably be removed. Remembe the 5 hours we spent on 280924 getting this completion to work.
  #Remember
  # home.sessionVariables.NIXD_FLAGS = "-log=error";

  # Enable Numlock (i.e. can type numbers)
  xsession.numlock.enable = true;

  programs.hmd = {
    enable = true;
    runOnSwitch = true; # enabled by default
  };

  imports = [
    ./zsh/zsh2.nix
    # ./fish/fish.nix
    ./nvim/nvim.nix
    #It doesn't make sense to use home-manager for our authorized keys file. It's weird but
    # ./ssh/ssh.nix
    # ../secrets/sops_home.nix
    ./utils/common.nix
  ];

  homelab.home.ssh.enable = true;

  # Environment
  home.sessionVariables = {
    EDITOR = "nvim";
    BROWSER = "firefox";
    TERMINAL = "kitty";
  };

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = (_: true);
    };
  };
  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    pkgs.tmux
    pkgs.git
    pkgs.gh
    pkgs.sops
    pkgs.age
    pkgs.ssh-to-age

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
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
    #
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


  # programs.git = {
  #   enable = true;
  #   userName = "abl030";
  #   userEmail = "abl030@g.m.a.i.l";
  # };
}
