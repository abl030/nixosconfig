{
  hostname,
  pkgs,
  ...
}: let
  ghosttySrc = builtins.path {
    path = ./.;
    name = "ghostty-config";
  };
in {
  home.packages = with pkgs; [
    ghostty
  ];
  home.file = {
    ".config/ghostty/config".source = "${ghosttySrc}/${hostname}";
  };
  programs.ghostty.enableZshIntegration = true;
}
