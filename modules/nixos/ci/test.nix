# modules/nixos/ci/test-stubborn-lints.nix
{
  pkgs,
  lib,
  cfg ? {},
  ...
}: let
  # Triggers: deprecated_to_path (introduced in statix v0.5.3).
  # Expect statix to complain; many versions don't auto-fix it.
  sysEtc = builtins.toPath "/etc";
in {
  # Triggers: empty_inherit (noop inherit-from with no names).
  # Intentionally empty — this should survive `statix fix`.
  inherit (pkgs);

  # Triggers: manual_inherit_from (fixable; statix will rewrite to `inherit (pkgs) jq;`)
  jq = pkgs.jq;

  # Triggers: bool_comparison (fixable to just `cfg.enable`)
  enableIt = cfg.enable == true;

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
