{
  lib,
  config,
  ...
}: let
  aliases = import ./aliases.nix {inherit lib config;};
in {
  imports = [
    ../../../home/utils/starship.nix
    ../../../home/utils/atuin.nix
    ./scripts.nix
  ];

  programs = {
    bash.shellAliases = aliases.sh;
    zsh.shellAliases = aliases.zsh;
    fish.shellAbbrs = aliases.fish;

    # Centralized zoxide configuration to prevent option duplication across shells
    # When multiple shells are enabled, setting options in each shell's config
    # causes Home Manager to incorrectly merge them (bug: --cmd cd --cmd cd --cmd cd)
    zoxide = {
      enable = true;
      options = ["--cmd cd"];
      enableBashIntegration = true;
      enableZshIntegration = true;
      enableFishIntegration = true;
    };
  };
}
