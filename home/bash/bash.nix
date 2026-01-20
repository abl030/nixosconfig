# ./home/bash/bash.nix
{
  lib,
  config,
  ...
}: {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
  ];

  programs = {
    bash = {
      enable = true;

      # --- Quality of Life Features ---
      enableCompletion = true;
      enableVteIntegration = true;

      # --- History Settings ---
      historyControl = ["ignoredups" "erasedups"];
      historySize = 10000;
      historyFileSize = 10000;

      # --- Aliases ---
      shellAliases = (import ../../modules/home-manager/shell/aliases.nix {inherit lib config;}).sh;

      # --- Custom Scripts and Initialization ---
      initExtra = ''
        export _RELOAD_FLAKE_PATH="${config.home.homeDirectory}/nixosconfig#"
      '';
    };

    starship.enableBashIntegration = true;
    zoxide = {
      enable = true;
      enableBashIntegration = true;
    };
    atuin.enableBashIntegration = true;
  };
}
