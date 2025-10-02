{...}: {
  programs.atuin = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    settings = {
      sync_address = "https://atuin.ablz.au";
    };
  };
}
