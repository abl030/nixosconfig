{
  pkgs,
  lib,
  ...
}:
# Intentionally "bad" to exercise the workflow.
let
  # deadnix: unused binding (will be auto-removed)
  topUnused = "remove me";
in {
  # statix: duplicate top-level key (will NOT be auto-fixed)
  homelab = {
    enable = true;
  };

  homelab = {
    enable = false;
  };

  # statix: typically warns about `with`; also fine to keep as extra noise
  environment.systemPackages = with pkgs; [
    jq
  ];
}
