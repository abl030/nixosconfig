# modules/nixos/ci/test-stubborn-lints.nix
{
  pkgs,
  lib,
  cfg ? {},
  ...
}: {
  # Triggers: empty_inherit (noop inherit-from with no names).
  # Intentionally empty — this should survive `statix fix`.

  # Triggers: manual_inherit_from (fixable; statix will rewrite to `inherit (pkgs) jq;`)
  inherit (pkgs) jq;

  # Triggers: bool_comparison (fixable to just `cfg.enable`)
  enableIt = cfg.enable;

  # Triggers: useless_has_attr (statix often prefers `cfg ? foo`; may or may not auto-fix)
  maybeFoo =
    if builtins.hasAttr "foo" cfg
    then cfg.foo
    else null;

  # Valid Nix; some statix versions misparse dynamic paths and emit E00 syntax errors.
  # Keeps the file "broken enough" across versions.
  interpolated = ./new/${lib.toLower "Name"}.nix;

  # Triggers: legacy_let_syntax / collapsible_let_in (fixable)
  legacy = let a = 1; in a + 1;
}
