{
  lib,
  config,
  pkgs,
  ...
}: {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
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
            # Inherited environments (e.g., launching zsh from fish/bash) may carry a
            # STARSHIP_CONFIG pointing at another shell’s theme. By setting it here to the
            # default Starship file, zsh consistently renders the “blue” theme regardless of
            # parent shells. Child processes will inherit this value; other shells will
            # assert their own STARSHIP_CONFIG in their own init paths.
            export STARSHIP_CONFIG="${config.home.homeDirectory}/.config/starship.toml"

            source ${./my_functions.sh}
            source ${./copycr.sh}

            # Bind Tab-Tab to accept the current autosuggestion.
            # ^I is the control character for the Tab key.
            bindkey '^I^I' autosuggest-accept

             # --- Fish-like Tab Completion ---
          # This enables the menu completion system. Hitting Tab repeatedly
          # will now cycle through the available options.
          zstyle ':completion:*:' menu select
          # This makes menu completion start automatically on the first Tab press
          # for an ambiguous completion. This makes it feel much more like Fish.
          setopt automenu

           # --- Rich, Descriptive Completion Display (The "Bling") ---
        # CORRECTED: Use "" for empty strings to avoid Nix syntax conflict.
        zstyle ':completion:*:' list-colors ""
        zstyle ':completion:*:' group-name ""
        # This one is fine as-is.
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

  # Optional: have gum available for fallback (not required)
  # home.packages = (config.home.packages or []) ++ [ pkgs.gum ];
}
