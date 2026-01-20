# ./home/bash/bash.nix
{config, ...}: {
  imports = [
    ../utils/starship.nix
    ../utils/atuin.nix
    ../../modules/home-manager/shell/scripts.nix
    ../../modules/home-manager/shell/core.nix
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
