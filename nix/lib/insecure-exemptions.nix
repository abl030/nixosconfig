# Insecure-package permits that announce their own expiry.
#
# nix/insecure-exemptions.json is the ONLY place the fleet may permit a
# package nixpkgs marks insecure (knownVulnerabilities). Each entry names the
# exact `pname-version`, the attribute that needs it (`neededBy`), and the
# hosts.nix hosts allowed to carry it. `stale` re-evaluates every `neededBy`
# on a package set with NO permits: if it now evaluates (or no longer exists),
# the permit is dead weight and must be deleted.
#
# Callers:
#   - modules/nixos/profiles/base.nix   -> forHost (per-host NixOS permit)
#   - flake.nix shared `pkgs`           -> all (standalone homeConfigurations)
#   - nix/checks/insecure-exemptions.nix -> hard failure when stale
#   - scripts/rolling_flake_update.sh   -> nightly warning + Gotify, non-blocking
# See docs/wiki/infrastructure/self-expiring-workarounds.md.
{lib}: let
  registry = lib.importJSON ../insecure-exemptions.json;
  names = builtins.attrNames registry;
in {
  inherit registry names;

  forHost = host: builtins.filter (n: builtins.elem host registry.${n}.hosts) names;

  stale = {
    nixpkgs,
    system,
    overlays ? [],
  }: let
    bare = import nixpkgs {
      inherit system overlays;
      config.allowUnfree = true;
    };
    path = attr: lib.splitString "." attr;
    evaluatesUnpermitted = attr:
      !(lib.hasAttrByPath (path attr) bare)
      || (builtins.tryEval
        (builtins.seq (lib.getAttrFromPath (path attr) bare).drvPath true)).success;
  in
    builtins.filter (n: evaluatesUnpermitted registry.${n}.neededBy) names;
}
