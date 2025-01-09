{ ... }:
{
  imports = [

    ../../home/home.nix
    ../../home/utils/common.nix
    # ../../home/utils/invidious.nix
  ];

  programs.zsh = {
    initExtra = ''
      export PATH="/mnt/c/Users/andy.b/AppData/Local/Microsoft/WinGet/Packages/equalsraf.win32yank_Microsoft.Winget.Source_8wekyb3d8bbwe:$PATH"
    '';
  };
}
 
