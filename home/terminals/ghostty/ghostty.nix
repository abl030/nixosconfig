{
  hostname,
  pkgs,
  ...
}: {
  home.packages = with pkgs; [
    ghostty
  ];
  home.file = {
    ".config/ghostty/config".source = ./. + "/${hostname}";
  };
  programs.ghostty.enableZshIntegration = true;
}
