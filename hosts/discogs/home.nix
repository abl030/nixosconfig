_: {
  # Service LXC: retain the shared minimal agent profile without importing the
  # desktop/workstation package set or fleet Atuin credentials.
  programs.atuin.enable = false;
  home.stateVersion = "25.05";
}
