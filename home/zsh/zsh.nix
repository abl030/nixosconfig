{ config, pkgs, ... }:

{
  imports = [
    ./theme.nix
    ./plugins.nix
  ];

  home.file = {
    ".zshrc2".source = ./.zshrc2;
  };
  programs.zsh = {
    initExtra = ''

      [[ ! -f ${config.home.homeDirectory}/.zshrc2 ]] || source ${config.home.homeDirectory}/.zshrc2
'';
  };
}
