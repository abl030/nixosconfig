{
  pkgs,
  ...
}:
# Intentionally "bad" to exercise the workflow.
{
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
