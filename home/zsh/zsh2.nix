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

        # Make cd resilient for environments where zoxide functions may not
        # be fully captured (e.g. Claude Code shell snapshots).
        # _ZO_DOCTOR=0 is set inside the function because shell snapshots
        # don't preserve variables, only functions/aliases/PATH.
        function cd() {
          _ZO_DOCTOR=0
          if (( ''${+functions[__zoxide_z]} )); then
            __zoxide_z "$@"
          else
            builtin cd "$@"
          fi
        }

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

    # zoxide configuration moved to modules/home-manager/shell/core.nix

    atuin.enableZshIntegration = true;
    starship.enableZshIntegration = true;
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };
}
