{ config, pkgs, ... }:

{
  imports = [
    # ./theme.nix
    ./plugins.nix
  ];

  programs.starship.enable = true;

  programs.starship.settings = {
    # Optional: Add a newline before the prompt like p10k can
    add_newline = false;

    # --- Git Status Configuration ---
    # See: https://starship.rs/config/#git-status

    git_status = {
      # Style for the entire status block (e.g., "[+1 ~2 !3 ?4]")
      # style = "bold blue"; # Or "white", "dimmed white", etc.

      # --- Symbols for different states ---
      staged = "[++\($count\)](green)"; # Symbol for staged changes count
      modified = "[++\($count\)](red)"; # Symbol for unstaged changes count
      untracked = "🤷"; # Symbol for untracked files count
      conflicted = "🏳"; # Symbol for conflicted files count
      renamed = "»"; # Symbol for renamed files count
      deleted = "✘"; # Symbol for deleted files count
      stashed = "$"; # Symbol shown when stashes exist

      # --- Formatting the output ---
      # This format string defines the order and appearance.
      # [$variable] only shows if the count > 0 or state exists.
      # ${ahead_behind} shows divergence like ⇡N ⇣M
      # Experiment with the order and separators!
      format = '' ([$all_status$ahead_behind]($style))'';
      # A slightly more spaced out version:
      # format = ''([\[$ahead_behind$stashed$staged$conflicted$modified$renamed$deleted$untracked\]]($style))'';
      # Or include literal spaces if you prefer:
      # format = ''([$ahead_behind ](208))([$stashed ](yellow))([$staged ](green))([$conflicted ](red))([$modified ](yellow))([$renamed ](yellow))([$deleted ](red))([$untracked ](cyan))'';



      # --- Behaviour ---
      disabled = false; # Keep it enabled
    };
  };
  home.packages = [
    pkgs.zsh-autocomplete
  ];

  home.file = {
    ".zshrc2".source = ./.zshrc2;
  };

  # programs.zsh.zprof.enable = true;

  programs.dircolors.enable = true;
  programs.dircolors.enableZshIntegration = true;
  programs.dircolors.settings = {
    OTHER_WRITABLE = "01;33"; # Change to yellow with bold text
  };

  programs.zsh = {
    history = {
      size = 10000;
      save = 10000;
    };
    initExtra = ''

      [[ ! -f ${config.home.homeDirectory}/.zshrc2 ]] || source ${config.home.homeDirectory}/.zshrc2
          source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh
                source ${pkgs.zsh-autocomplete}/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh
                zstyle ':completion:*:default' list-colors 'di=0;37'
                zstyle ':autocomplete:history-search-backward:*' list-lines 2000
'';
  };
}
