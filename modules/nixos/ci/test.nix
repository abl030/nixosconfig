# modules/linting_test/trigger.nix
# Purpose:
# - deadnix will autofix:
#     * remove the unused function arg `foo`
#     * remove the unused `let` binding `unused`
# - statix will still warn:
#     * repeated top-level key `environment` (W20) – not auto-fixable
{
  lib,
  pkgs,
  foo,
  ...
}: let
  # deadnix: this is unused and will be deleted
  unused = pkgs.cowsay;
in {
  # Using `with` often gets a statix nudge, and it's fine to keep.
  environment = {
    systemPackages = with pkgs; [
      hello
    ];
  };

  # asdlkjfDuplicate top-level key to trigger statix W20 (avoid repeated keys in attr sets)
  environment = {
    variables = {FOO = "bar";};
  };
}
