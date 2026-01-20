# ./home/zsh/zsh2.nix
{config, ...}: {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
    ../../modules/home-manager/shell/core.nix
  ];

  programs = {
    zsh = {
      enable = true;
      autosuggestion.enable = true;
      enableCompletion = true;
      syntaxHighlighting.enable = true;

      initContent = ''
        _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"
        export STARSHIP_CONFIG="${config.home.homeDirectory}/.config/starship.toml"

        # Bind Tab-Tab to accept the current autosuggestion.
        bindkey '^I^I' autosuggest-accept

        # --- Fish-like Tab Completion ---
        zstyle ':completion:*:' menu select
        setopt automenu

        # --- Rich, Descriptive Completion Display ---
        zstyle ':completion:*:' list-colors ""
        zstyle ':completion:*:' group-name ""
        zstyle ':completion:*:descriptions' format 'Completing %d'
        zstyle ':completion:*' verbose yes
      '';
    };

    zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    atuin.enableZshIntegration = true;
    starship.enableZshIntegration = true;
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };
}
