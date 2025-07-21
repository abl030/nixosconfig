{ config, pkgs, ... }:

let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in

{

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
    };

    # Source our separate, syntax-highlighted functions file.
    initContent = ''
      source ${./my_functions.zsh}
    '';

  };
  programs.zoxide.enableZshIntegration = true;
}

