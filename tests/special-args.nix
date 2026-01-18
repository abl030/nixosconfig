# Test: Special Arguments Injection
# ==================================
# Verifies that nix/lib.nix factory injects required arguments.
# These tests check that the effects of special args are visible in config.
# Run with: nix eval .#tests.special-args --apply 'x: x.summary'
#
{ nixosConfigurations, homeConfigurations, hosts }:
let
  lib = import <nixpkgs/lib>;

  # Filter out special entries
  hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;

  # HM-only hosts (those without configurationFile)
  hmOnlyHosts = lib.filterAttrs (name: host: !(host ? configurationFile)) hostEntries;

  # Test a NixOS configuration for expected outcomes of special args injection
  testNixosConfig = name: cfg:
    let
      config = cfg.config;
      hostEntry = hosts.${name};

      tests = {
        # hostname special arg should result in correct networking.hostName
        "hostname-set" = {
          description = "networking.hostName matches hosts.nix";
          passed = config.networking.hostName == hostEntry.hostname;
          expected = hostEntry.hostname;
          actual = config.networking.hostName;
        };

        # hostConfig.user should result in user being created
        "user-created" = {
          description = "user from hosts.nix exists";
          passed = config.users.users ? ${hostEntry.user};
          expected = "users.users.${hostEntry.user} exists";
          actual = if config.users.users ? ${hostEntry.user} then "exists" else "missing";
        };

        # allHosts should result in known_hosts being populated (for non-sandbox hosts with identity)
        "known-hosts-populated" = {
          description = "SSH known_hosts contains fleet members";
          passed =
            let
              knownHosts = config.programs.ssh.knownHosts or {};
              # Should have at least some homelab- prefixed entries
              homelabEntries = lib.filterAttrs (n: _: lib.hasPrefix "homelab-" n) knownHosts;
            in builtins.length (builtins.attrNames homelabEntries) > 0;
          expected = "at least 1 homelab-* known_hosts entry";
          actual = toString (builtins.length (builtins.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "homelab-" n) (config.programs.ssh.knownHosts or {}))));
        };

        # flakes should be enabled (set by base profile using hostConfig access)
        "flakes-enabled" = {
          description = "nix flakes experimental feature enabled";
          passed = builtins.elem "flakes" (config.nix.settings.experimental-features or []);
          expected = "flakes in experimental-features";
          actual = toString (config.nix.settings.experimental-features or []);
        };
      };

      failedTests = lib.filterAttrs (_: t: !t.passed) tests;
    in {
      inherit name tests;
      passed = builtins.length (builtins.attrNames failedTests) == 0;
      failedCount = builtins.length (builtins.attrNames failedTests);
      failures = failedTests;
    };

  # Test Home Manager-only configurations
  testHomeConfig = name: cfg:
    let
      hostEntry = hosts.${name};

      tests = {
        # Basic check - activation package should exist
        "activation-exists" = {
          description = "activationPackage exists";
          passed = cfg ? activationPackage;
          expected = "activationPackage attribute";
          actual = if cfg ? activationPackage then "exists" else "missing";
        };
      };

      failedTests = lib.filterAttrs (_: t: !t.passed) tests;
    in {
      inherit name tests;
      passed = builtins.length (builtins.attrNames failedTests) == 0;
      failedCount = builtins.length (builtins.attrNames failedTests);
      failures = failedTests;
    };

  # Run tests on all NixOS configurations
  nixosResults = lib.mapAttrs testNixosConfig nixosConfigurations;

  # Run tests on HM-only configurations (filter to just HM-only hosts)
  hmOnlyConfigs = lib.filterAttrs (name: _: hmOnlyHosts ? ${name}) homeConfigurations;
  homeResults = lib.mapAttrs testHomeConfig hmOnlyConfigs;

  # Combine results (no overlap now since HM-only and NixOS are disjoint)
  allResults = nixosResults // homeResults;

  # Count failures
  totalFailures = lib.foldl' (acc: r: acc + r.failedCount) 0 (builtins.attrValues allResults);

  # Format a single result
  formatResult = name: result:
    let
      testLines = lib.mapAttrsToList (tname: t:
        if t.passed
        then "    PASS: ${tname}"
        else "    FAIL: ${tname} - expected ${t.expected}, got ${t.actual}"
      ) result.tests;
    in "  ${name}:\n${lib.concatStringsSep "\n" testLines}";

  summary = ''

    === Special Arguments Injection Tests ===
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatResult allResults)}

    Total hosts tested: ${toString (builtins.length (builtins.attrNames allResults))}
    Total failures: ${toString totalFailures}
    ${if totalFailures == 0 then "Status: ALL TESTS PASSED" else "Status: TESTS FAILED"}
  '';

in {
  inherit allResults nixosResults homeResults;
  passed = totalFailures == 0;
  inherit summary;

  check =
    if totalFailures == 0
    then true
    else throw "Special args tests failed with ${toString totalFailures} failures";
}
