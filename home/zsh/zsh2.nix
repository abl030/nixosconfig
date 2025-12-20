# ./home/zsh/zsh2.nix
{
  lib,
  config,
  ...
}: {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
  ];

  # Group all program configurations into a single `programs` attribute set to avoid repetition warnings.
  programs = {
    zsh = {
      enable = true;
      autosuggestion.enable = true;
      enableCompletion = true;
      syntaxHighlighting.enable = true;

      shellAliases = (import ../../modules/home-manager/shell/aliases.nix {inherit lib config;}).zsh;

      # Source our separate, syntax-highlighted functions file(s).
      initContent = ''
            # Nix expands ${config.home.homeDirectory} *here*.
            _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"

            # Assert per-shell Starship theme for zsh:
            export STARSHIP_CONFIG="${config.home.homeDirectory}/.config/starship.toml"

            source ${./my_functions.sh}
            source ${./copycr.sh}

            # Bind Tab-Tab to accept the current autosuggestion.
            bindkey '^I^I' autosuggest-accept

             # --- Fish-like Tab Completion ---
          zstyle ':completion:*:' menu select
          setopt automenu

           # --- Rich, Descriptive Completion Display (The "Bling") ---
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

    # NEW: Enable fzf for the TUI (preferred path; minimal change)
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };
}
