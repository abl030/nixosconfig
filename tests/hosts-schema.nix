# Test: hosts.nix Schema Validation
# ==================================
# Verifies that all host entries conform to expected structure.
# Run with: nix-instantiate --eval tests/hosts-schema.nix --strict
#
{ hostsFile ? ../hosts.nix }:
let
  hosts = import hostsFile;

  lib = import <nixpkgs/lib>;

  # Filter out special entries (prefixed with _)
  hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;

  # Required fields for ALL hosts
  baseRequiredFields = [
    "hostname"
    "user"
    "homeDirectory"
    "publicKey"
    "authorizedKeys"
    "homeFile"
    "sshAlias"
  ];

  # Additional fields required for NixOS hosts (those with configurationFile)
  nixosRequiredFields = baseRequiredFields ++ [
    "configurationFile"
  ];

  # Validate a single host entry
  validateHost = name: host:
    let
      isNixosHost = host ? configurationFile;
      requiredFields = if isNixosHost then nixosRequiredFields else baseRequiredFields;

      # Check each required field
      missingFields = builtins.filter (field: !(host ? ${field})) requiredFields;
      hasMissingFields = builtins.length missingFields > 0;

      # Validate publicKey format (should start with ssh-ed25519) - only if field exists
      publicKeyValid = if host ? publicKey
        then lib.hasPrefix "ssh-ed25519 " host.publicKey
        else true; # Will be caught by missing fields check

      # Validate authorizedKeys is a list - only if field exists
      authorizedKeysValid = if host ? authorizedKeys
        then builtins.isList host.authorizedKeys
        else true; # Will be caught by missing fields check

      # Validate proxmox structure if present
      proxmoxValid = if host ? proxmox then
        (host.proxmox ? vmid) &&
        (host.proxmox ? cores) &&
        (host.proxmox ? memory) &&
        (host.proxmox ? disk)
      else true;

      # Collect all errors
      errors =
        (if hasMissingFields then ["missing required fields: ${toString missingFields}"] else []) ++
        (if !publicKeyValid then ["publicKey must start with 'ssh-ed25519 '"] else []) ++
        (if !authorizedKeysValid then ["authorizedKeys must be a list"] else []) ++
        (if !proxmoxValid then ["proxmox config missing required fields (vmid, cores, memory, disk)"] else []);

    in {
      inherit name;
      isNixosHost = isNixosHost;
      valid = builtins.length errors == 0;
      errors = errors;
    };

  # Run validation on all hosts
  results = lib.mapAttrs validateHost hostEntries;

  # Collect failures
  failures = lib.filterAttrs (_: result: !result.valid) results;
  failureCount = builtins.length (builtins.attrNames failures);

  # Format results for output
  formatResult = name: result:
    if result.valid
    then "  PASS: ${name} (${if result.isNixosHost then "NixOS" else "HM-only"})"
    else "  FAIL: ${name} - ${toString result.errors}";

  resultLines = lib.mapAttrsToList formatResult results;

  summary = ''

    === hosts.nix Schema Validation ===
    ${lib.concatStringsSep "\n" resultLines}

    Total: ${toString (builtins.length (builtins.attrNames results))} hosts
    Passed: ${toString (builtins.length (builtins.attrNames results) - failureCount)}
    Failed: ${toString failureCount}
    ${if failureCount == 0 then "Status: ALL TESTS PASSED" else "Status: TESTS FAILED"}
  '';

in {
  # Return structured results for programmatic use
  inherit results failures;
  passed = failureCount == 0;

  # Human-readable summary
  summary = summary;

  # For test runner - throws on failure
  check =
    if failureCount == 0
    then true
    else throw "Schema validation failed for: ${toString (builtins.attrNames failures)}";
}
