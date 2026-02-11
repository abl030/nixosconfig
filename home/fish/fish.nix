# ./home/fish/fish.nix
{config, ...}: let
  flakeBase = "${config.home.homeDirectory}/nixosconfig";
in {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
    ../../modules/home-manager/shell/core.nix
  ];

  programs = {
    fish = {
      enable = true;

      shellInit = ''
        set -gx _RELOAD_FLAKE_PATH "${flakeBase}#"
      '';
    };

    starship.enableFishIntegration = true;

    # zoxide configuration moved to modules/home-manager/shell/core.nix

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
