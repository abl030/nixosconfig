# Test: Sops Secret Paths
# =======================
# Verifies that referenced secret files exist.
# Run with: nix eval .#tests.sops-paths --apply 'x: x.summary'
#
{ nixosConfigurations, lib, flakeRoot }:
let
  # Check if a sops file path exists
  checkSopsFile = path:
    let
      # sopsFile paths are usually relative to the module, need to resolve
      # In practice, they're often absolute paths or use ../../../ patterns
      # We'll check the string representation
      pathStr = toString path;
      exists = builtins.pathExists path;
    in {
      path = pathStr;
      inherit exists;
    };

  # Extract sops secrets from a NixOS config
  getSopsSecrets = name: cfg:
    let
      secrets = cfg.config.sops.secrets or {};
      secretChecks = lib.mapAttrs (secretName: secret:
        if secret ? sopsFile then
          checkSopsFile secret.sopsFile
        else
          { path = "inline/no-file"; exists = true; }
      ) secrets;
    in {
      inherit name;
      secretCount = builtins.length (builtins.attrNames secrets);
      secrets = secretChecks;
      missingFiles = lib.filterAttrs (_: s: !s.exists) secretChecks;
      hasMissing = builtins.length (builtins.attrNames (lib.filterAttrs (_: s: !s.exists) secretChecks)) > 0;
    };

  results = lib.mapAttrs getSopsSecrets nixosConfigurations;

  # Count hosts with missing secrets
  hostsWithMissing = lib.filterAttrs (_: r: r.hasMissing) results;
  totalMissing = lib.foldl' (acc: r:
    acc + builtins.length (builtins.attrNames r.missingFiles)
  ) 0 (builtins.attrValues results);

  formatResult = name: result:
    if result.secretCount == 0 then
      "  ${name}: no sops secrets configured"
    else if result.hasMissing then
      "  ${name}: ${toString result.secretCount} secrets, MISSING: ${toString (builtins.attrNames result.missingFiles)}"
    else
      "  ${name}: ${toString result.secretCount} secrets, all files exist";

  summary = ''

    === Sops Secret Path Tests ===

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatResult results)}

    Summary:
      Hosts checked: ${toString (builtins.length (builtins.attrNames results))}
      Hosts with missing files: ${toString (builtins.length (builtins.attrNames hostsWithMissing))}
      Total missing files: ${toString totalMissing}

    ${if totalMissing == 0
      then "Status: ALL TESTS PASSED"
      else "Status: TESTS FAILED - ${toString totalMissing} secret files missing"}

    Note: Missing secret files will cause boot failures when sops-nix tries to decrypt them.
  '';

  passed = totalMissing == 0;

in {
  inherit results hostsWithMissing;
  inherit passed summary;

  check =
    if passed
    then true
    else throw "Sops path tests failed - ${toString totalMissing} secret files missing";
}
