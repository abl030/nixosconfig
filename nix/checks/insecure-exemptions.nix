# Insecure-package exemptions must be registered, scoped and still needed.
# See nix/lib/insecure-exemptions.nix and
# docs/wiki/infrastructure/self-expiring-workarounds.md.
{
  self,
  lib,
  pkgs,
  hosts,
  inputs,
}: let
  exemptions = import ../lib/insecure-exemptions.nix {inherit lib;};
  inherit (exemptions) registry names;

  staleNames = exemptions.stale {
    inherit (inputs) nixpkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = import ../overlay.nix {inherit inputs;};
  };

  required = ["neededBy" "hosts" "since" "reason" "tracking"];
  problems = lib.concatMap (n: let
    e = registry.${n};
  in
    map (f: "${n}: missing or empty `${f}`")
    (builtins.filter (f: !(e ? ${f}) || e.${f} == "" || e.${f} == []) required)
    ++ map (h: "${n}: host `${h}` is not in hosts.nix")
    (builtins.filter (h: !(hosts ? ${h})) (e.hosts or [])))
  names;
in {
  # Hard failure the moment an exemption stops being needed. The nightly
  # populate_cache.sh skips this one: rolling_flake_update.sh reports it as a
  # non-blocking warning instead, so a dead permit never holds back nixpkgs.
  insecureExemptionsFresh =
    if staleNames != []
    then
      throw ''
        STALE INSECURE EXEMPTION: ${lib.concatMapStringsSep ", " (n: "${n} (neededBy ${registry.${n}.neededBy})") staleNames}
        The dependent package now evaluates without the permit, so it is no
        longer needed. Delete the entry from nix/insecure-exemptions.json.
      ''
    else
      pkgs.runCommand "insecure-exemptions-fresh" {} ''
        echo "${toString (builtins.length names)} insecure exemption(s), all still needed"
        touch $out
      '';

  # Registry entries are complete and name real hosts, and nothing outside the
  # registry plumbing permits insecure packages ad hoc.
  insecureExemptionsRegistry = assert lib.assertMsg (problems == [])
  "nix/insecure-exemptions.json:\n${lib.concatStringsSep "\n" problems}";
    pkgs.runCommand "insecure-exemptions-registry" {} ''
      cd ${self}
      hits=$(${pkgs.gnugrep}/bin/grep -rlE 'permittedInsecurePackages|allowInsecurePredicate|NIXPKGS_ALLOW_INSECURE' \
        --include='*.nix' --include='*.sh' --include='*.py' . \
        | ${pkgs.gnugrep}/bin/grep -vxE './(flake\.nix|modules/nixos/profiles/base\.nix|nix/lib/insecure-exemptions\.nix|nix/checks/insecure-exemptions\.nix)' || true)
      if [ -n "$hits" ]; then
        echo "Insecure-package permits must come from nix/insecure-exemptions.json; found ad hoc use in:" >&2
        echo "$hits" >&2
        exit 1
      fi
      touch $out
    '';
}
