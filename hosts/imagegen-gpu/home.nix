_: {
  # Appliance VM: keep the shared minimal agent profile without the
  # desktop/workstation package set or fleet Atuin credentials (this host sets
  # atuinCredentials = false in hosts.nix, so the secret is never deployed).
  programs.atuin.enable = false;
  home.stateVersion = "25.05";
}
