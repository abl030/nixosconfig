{ config, pkgs, ... }:

let
  # Define the path to your scripts directory for cleaner aliases.
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in
{
  # Import modules for tools that will be integrated into the shell.
  imports = [
    ../zsh/starship.nix # Starship config is shell-agnostic, we can reuse it.
    ../utils/atuin.nix
  ];

  programs.bash = {
    enable = true;

    # --- Quality of Life Features ---
    enableCompletion = true; # Enable standard bash-completion.
    enableVteIntegration = true; # Helps terminals track the current directory.

    # --- History Settings ---
    # Replicate some of Zsh's sensible history defaults.
    historyControl = [ "ignoredups" "erasedups" ];
    historySize = 10000;
    historyFileSize = 10000;

    # --- Aliases ---
    # Directly translated from your zsh config.
    shellAliases = {
      "epi!" = "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'";
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
    };

    # --- Custom Scripts and Initialization ---
    initExtra = ''
      # Define the flake path variable for our functions.
      # This is the Bash equivalent of the 'set -l' in your Zsh functions.
      export _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"
      
      # Source our custom functions file.
      source ${./my_functions.bash}
    '';
  };

  # --- Program Integrations ---

  programs.starship.enableBashIntegration = true;

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.atuin = {
    # Configuration is in the imported atuin.nix
    enableBashIntegration = true;
  };

  # Note on Autocomplete:
  # Bash does not have a direct equivalent to Zsh's powerful autosuggestions
  # or syntax highlighting out of the box. `enableCompletion` provides
  # standard tab-completion, which is the primary QoL feature for Bash.
}
