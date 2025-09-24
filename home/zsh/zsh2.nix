{ lib, config, pkgs, ... }:

let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in

{

  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
  ];

  programs.zsh = {
    enable = true;

    autosuggestion.enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;

    shellAliases = (import ../../modules/home-manager/shell/aliases.nix { inherit lib config; }).zsh;
    # Source our separate, syntax-highlighted functions file(s).
    initContent = ''
            # Nix expands ${config.home.homeDirectory} *here*.
          _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"
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

  programs.zoxide.enable = true;
  programs.zoxide.enableZshIntegration = true;
  programs.atuin.enableZshIntegration = true;
  programs.starship.enableZshIntegration = true;

  # NEW: Enable fzf for the TUI (preferred path; minimal change)
  programs.fzf.enable = true;
  programs.fzf.enableZshIntegration = true;

  # Optional: have gum available for fallback (not required)
  # home.packages = (config.home.packages or []) ++ [ pkgs.gum ];
}

