# Test: Derivation Snapshots
# ==========================
# Compares build outputs against known baselines.
# Use update-baselines.sh to create/update baseline files after intentional changes.
#
# IMPORTANT: This test must be run via the flake context to match baseline generation:
#   nix eval .#tests.snapshots --apply 'x: x.summary'
#
# The baselines are generated with `nix eval .#nixosConfigurations.X...` so the test
# must use the same evaluation context. Using builtins.getFlake will produce different
# derivations due to different purity contexts.
#
{ nixosConfigurations, homeConfigurations, pkgs, lib, baselinesDir }:
let
  # Get the store path for a NixOS system's toplevel
  # Note: These paths must match what update-baselines.sh generates
  getNixosToplevel = name: cfg:
    builtins.unsafeDiscardStringContext (toString cfg.config.system.build.toplevel);

  # Get the store path for a Home Manager activation package
  getHomeActivation = name: cfg:
    builtins.unsafeDiscardStringContext (toString cfg.activationPackage);

  # Current derivation paths
  currentNixos = lib.mapAttrs getNixosToplevel nixosConfigurations;
  currentHome = lib.mapAttrs getHomeActivation homeConfigurations;

  # Try to read baseline file, return null if not found
  readBaseline = name: type:
    let
      path = baselinesDir + "/${type}-${name}.txt";
    in
      if builtins.pathExists path
      then lib.removeSuffix "\n" (builtins.readFile path)
      else null;

  # Compare NixOS configurations
  nixosResults = lib.mapAttrs (name: current:
    let
      baseline = readBaseline name "nixos";
    in {
      inherit name current baseline;
      hasBaseline = baseline != null;
      matches = baseline == current;
      status =
        if baseline == null then "no-baseline"
        else if baseline == current then "match"
        else "changed";
    }
  ) currentNixos;

  # Compare Home Manager configurations
  homeResults = lib.mapAttrs (name: current:
    let
      baseline = readBaseline name "home";
    in {
      inherit name current baseline;
      hasBaseline = baseline != null;
      matches = baseline == current;
      status =
        if baseline == null then "no-baseline"
        else if baseline == current then "match"
        else "changed";
    }
  ) currentHome;

  # Count statuses
  countStatus = results: status:
    lib.count (r: r.status == status) (builtins.attrValues results);

  nixosMatches = countStatus nixosResults "match";
  nixosChanged = countStatus nixosResults "changed";
  nixosNoBaseline = countStatus nixosResults "no-baseline";

  homeMatches = countStatus homeResults "match";
  homeChanged = countStatus homeResults "changed";
  homeNoBaseline = countStatus homeResults "no-baseline";

  # Format result
  formatResult = type: name: result:
    let
      icon = {
        "match" = "MATCH";
        "changed" = "CHANGED";
        "no-baseline" = "NO-BASELINE";
      }.${result.status};
    in "  ${icon}: ${type}/${name}";

  summary = ''

    === Derivation Snapshot Tests ===

    NixOS Configurations:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (formatResult "nixos") nixosResults)}

    Home Manager Configurations:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (formatResult "home") homeResults)}

    Summary:
      NixOS: ${toString nixosMatches} match, ${toString nixosChanged} changed, ${toString nixosNoBaseline} no baseline
      Home:  ${toString homeMatches} match, ${toString homeChanged} changed, ${toString homeNoBaseline} no baseline

    ${if nixosChanged > 0 || homeChanged > 0
      then "Status: CHANGES DETECTED - review and update baselines if intentional"
      else if nixosNoBaseline > 0 || homeNoBaseline > 0
      then "Status: BASELINES MISSING - run update-baselines.sh to create"
      else "Status: ALL SNAPSHOTS MATCH"}

    Note: Run ./tests/update-baselines.sh to update baselines after intentional changes.
  '';

  # For the check - we pass if there are no changes (missing baselines are OK)
  hasChanges = nixosChanged > 0 || homeChanged > 0;

in {
  nixos = nixosResults;
  home = homeResults;
  current = {
    nixos = currentNixos;
    home = currentHome;
  };
  passed = !hasChanges;
  inherit summary;

  # For generating baseline files
  baselineContent = {
    nixos = lib.mapAttrs (_: r: r.current) nixosResults;
    home = lib.mapAttrs (_: r: r.current) homeResults;
  };

  check =
    if !hasChanges
    then true
    else throw "Derivation snapshots have changed - review and update baselines if intentional";
}
