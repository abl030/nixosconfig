# This module defines a simple configuration and does not need any inputs like pkgs or config.
# The function signature `{...}` is replaced with `_` to make it explicit that no arguments are being used.
_: {
  programs.atuin = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    settings = {
      sync_address = "https://atuin.ablz.au";
    };
  };
}
