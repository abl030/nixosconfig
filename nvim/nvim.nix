{ config, inputs, home, pkgs, ... }:
{
  home.packages = [
    #These packages are for installing through mason. But we can't do that so I am commenting them out here but leaving them
    # pkgs.nvchad
    # pkgs.zip
    # pkgs.unzip
    # pkgs.python3
    # pkgs.cargo

    #XClip is needed to yank through X11 through ssh sessions
    pkgs.xclip

    #And these are all our lovely language server types things. These all need to be installed here as mason simply does not work
    #Well it might but it will super stuff up your install so don't do it.
    pkgs.shellcheck
    pkgs.nixd
    pkgs.stylua
    pkgs.yamlfmt
    pkgs.rustfmt
    pkgs.prettierd
    pkgs.beautysh
    pkgs.nixpkgs-fmt
    pkgs.black
    pkgs.isort
    pkgs.yaml-language-server
    pkgs.marksman
    pkgs.pyright
    pkgs.bash-language-server
    pkgs.vscode-langservers-extracted
    pkgs.jsonfmt
    pkgs.jq
    pkgs.eslint_d
    pkgs.typescript-language-server


  ];


  imports = [
    inputs.nvchad4nix.homeManagerModule
  ];

  home.file = {
    #Define all the plugins we want to use. this needs a clean out.
    ".config/nvim/lua/plugins/plugins.lua".source = ./plugins.lua;
    # This is our main option file. This is also now aliased to "edit nvim"
    ".config/nvim/lua/options2.lua".source = ./options.lua;
    #Defining how we want to use our lsp config.
    ".config/nvim/lua/configs/lspconfig2.lua".source = ./lspconfig.lua;
    #Edit any UI options we want, currently just want that dashboard.
    ".config/nvim/lua/chadrc_editor.lua".source = ./chadrc_editor.lua;
    #This is a lot of our old crusty keybindings. This also needs to be sorted through
    "vim.vim".source = ./vim.vim;
  };
  programs.nvchad.extraConfig = ''

    require "options2"
    require "configs.lspconfig2"
    require "chadrc_editor"


  '';
  programs.nvchad.enable = true;
}
