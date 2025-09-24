# ./home/fish/fish.nix
{ lib, config, pkgs, ... }:

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
    shellAbbrs = (import ../../modules/home-manager/shell/aliases.nix { inherit lib config; }).fish;
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

