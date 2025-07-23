{ config, pkgs, ... }:

let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in

{

  imports = [
    ./starship.nix
    ../utils/atuin.nix
  ];
  programs.zsh = {
    enable = true;

    autosuggestion.enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;


    shellAliases = {
      "epi!" = "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'"; # Quoted due to '!'
      epi = "wakeonlan 18:c0:4d:65:86:e8";
      cd = "z";
      cdi = "zi";
      restart_bluetooth = "bash ${scriptsPath}/bluetooth_restart.sh";
      tb = "bash ${scriptsPath}/trust_buds.sh";
      cb = "bluetoothctl connect 24:24:B7:58:C6:49";
      dcb = "bluetoothctl disconnect 24:24:B7:58:C6:49";
      rb = "bash ${scriptsPath}/repair_buds.sh";
      pb = "bash ${scriptsPath}/pair_buds.sh";
      ytlisten = "mpv --no-video --ytdl-format=bestaudio --msg-level=ytdl_hook=debug";
      ssh_epi = "epi!; and ssh epi";
      clear_dots = "git stash; and git stash clear";
      clear_flake = "git restore flake.lock && pull_dotfiles";
      lzd = "lazydocker";
      v = "nvim";
      ls = "lsd -A -F -l --group-directories-first --color=always";
      lzg = "lazygit";
      ytsum = "noglob ytsum";
    };

    # Source our separate, syntax-highlighted functions file.
    initContent = ''
            # Nix expands ${config.home.homeDirectory} *here*.
          _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"
            source ${./my_functions.zsh}

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
  programs.zoxide.enableZshIntegration = true;
}

