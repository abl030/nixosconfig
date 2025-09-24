# ./home/fish/fish.nix
{ config, pkgs, ... }:

let
  flakeBase = "${config.home.homeDirectory}/nixosconfig";
  zshDir = "${flakeBase}/home/zsh"; # my_functions.sh + copycr.sh live here
  scriptsPath = "${flakeBase}/scripts"; # for your helper scripts
in
{
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
  ];

  programs.fish = {
    enable = true;

    # keep env in sync with zsh/bash usage
    shellInit = ''
      set -gx _RELOAD_FLAKE_PATH "${flakeBase}#"
    '';

    # one tiny adapter to run your bash-compatible functions
    functions.__bash_call = ''
      set -l func $argv[1]
      set -e argv[1]
      bash -lc 'source "'"${zshDir}"'/my_functions.sh"; source "'"${zshDir}"'/copycr.sh"; '"$func"' "$@"' -- $argv
      return $status
    '';

    # wrappers matching your zsh function names
    functions.reload = '' __bash_call reload $argv '';
    functions.update = '' __bash_call update $argv '';
    functions.copyc = '' __bash_call copyc  $argv '';
    functions.copycr = '' __bash_call copycr $argv '';
    functions.teec = '' __bash_call teec   $argv '';
    functions.ytsum = '' __bash_call ytsum  $argv '';

    # same “aliases” (fish abbrs) you use elsewhere
    shellAbbrs = {
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
  };

  # same integrations you have for zsh
  programs.starship.enableFishIntegration = true;

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.atuin.enable = true;
  programs.atuin.enableFishIntegration = true;

  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };
}

