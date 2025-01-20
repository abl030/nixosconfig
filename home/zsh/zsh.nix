{ config, pkgs, ... }:

{
  imports = [
    ./theme.nix
    ./plugins.nix
  ];

  home.packages = [
    pkgs.zsh-autocomplete
  ];

  home.file = {
    ".zshrc2".source = ./.zshrc2;
  };

  # programs.zsh.zprof.enable = true;

  programs.zsh = {
    initExtra = ''

      [[ ! -f ${config.home.homeDirectory}/.zshrc2 ]] || source ${config.home.homeDirectory}/.zshrc2
          source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh
'';
  };
}
