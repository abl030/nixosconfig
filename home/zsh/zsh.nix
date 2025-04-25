{ config, pkgs, ... }:

{
  imports = [
    # ./theme.nix
    ./plugins.nix
    ./starship.nix
  ];



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
