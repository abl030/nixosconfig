{ pkgs, ... }:

{
  programs.atuin = {
    enable = true;
    enableFishIntegration = true;
    settings = {
      sync_address = "https://atuin.ablz.au";
    };
  };
}
