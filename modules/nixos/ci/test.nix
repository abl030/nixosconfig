# modules/linting_test/trigger.nix
# Purpose:
# - deadnix will autofix:
#     * remove the unused function arg `foo`
#     * remove the unused `let` binding `unused`
# - statix will still warn:
#     * repeated top-level key `environment` (W20) – not auto-fixable
{
  pkgs,
  ...
}: {
  # Using `with` often gets a statix nudge, and it's fine to keep.
  environment = {
    systemPackages = with pkgs; [
      hello
    ];
  };

  # Duplicate top-level key to trigger statix W20 (avoid repeated keys in attr sets)
  environment = {
    variables = {FOO = "bar";};
  };
}
