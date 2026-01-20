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
  };
}
