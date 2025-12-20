# ./home/fish/fish.nix
{
  lib,
  config,
  ...
}: let
  flakeBase = "${config.home.homeDirectory}/nixosconfig";
in {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
  ];

  programs = {
    fish = {
      enable = true;

      shellInit = ''
        set -gx STARSHIP_CONFIG "${config.home.homeDirectory}/.config/starship-fish.toml"
        set -gx _RELOAD_FLAKE_PATH "${flakeBase}#"
      '';

      # Abbreviations
      shellAbbrs = (import ../../modules/home-manager/shell/aliases.nix {inherit lib config;}).fish;
    };

    starship.enableFishIntegration = true;

    zoxide = {
      enable = true;
      enableFishIntegration = true;
    };

    atuin = {
      enable = true;
      enableFishIntegration = true;
    };

    fzf = {
      enable = true;
      enableFishIntegration = true;
    };
  };
}
