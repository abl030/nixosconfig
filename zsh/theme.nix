{ config, pkgs, ... }:

{
  home.file = {
    ".p10k.zsh".source = ./.p10k.zsh;
  };
  programs.zsh = {
    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
    ];
    # Ok so this inits our p10k config. Have to wrap it in these conf.home things
    #Because it's not modularised and the direct paths weren't working. 
    initExtra = ''
      [[ ! -f ${config.home.homeDirectory}/.p10k.zsh ]] || source ${config.home.homeDirectory}/.p10k.zsh
    '';
  };
}

