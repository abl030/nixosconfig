{ config, pkgs, ... }:

{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
    syntaxHighlighting.enable = true;
    oh-my-zsh = {
      enable = true;
      plugins = [
        "tmux"
        "common-aliases"
        "copypath"
        "copyfile"
        "ubuntu"
        "git"
        "history"
        "history-substring-search"
        "rust"
        "pyenv"
      ];
    };
    zplug = {
      enable = true;
      plugins = [
        { name = "tamcore/autoupdate-oh-my-zsh-plugins"; }
        # { name = "zsh-users/zsh-syntax-highlighting"; }
        { name = "marlonrichert/zsh-autocomplete"; }
        # { name = "zsh-users/zsh-autosuggestions"; }
      ];
    };

  };
}

