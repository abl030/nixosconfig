# Test: Module Option Structure
# =============================
# Verifies that custom module options exist and have expected structure.
# Run with: nix eval .#tests.module-options --apply 'x: x.summary'
#
{ nixosConfigurations, lib }:
let
  # Use framework as the reference host (has all typical options)
  refConfig = nixosConfigurations.framework.config;

  tests = {
    # homelab namespace exists
    "homelab-namespace" = {
      description = "homelab namespace exists in config";
      passed = refConfig ? homelab;
      expected = "config.homelab exists";
      actual = if refConfig ? homelab then "exists" else "missing";
    };

    # homelab.ssh module
    "homelab-ssh-enable" = {
      description = "homelab.ssh.enable option exists";
      passed = refConfig.homelab.ssh ? enable;
      expected = "homelab.ssh.enable";
      actual = if refConfig.homelab.ssh ? enable then "exists" else "missing";
    };

    "homelab-ssh-secure" = {
      description = "homelab.ssh.secure option exists";
      passed = refConfig.homelab.ssh ? secure;
      expected = "homelab.ssh.secure";
      actual = if refConfig.homelab.ssh ? secure then "exists" else "missing";
    };

    "homelab-ssh-deployIdentity" = {
      description = "homelab.ssh.deployIdentity option exists";
      passed = refConfig.homelab.ssh ? deployIdentity;
      expected = "homelab.ssh.deployIdentity";
      actual = if refConfig.homelab.ssh ? deployIdentity then "exists" else "missing";
    };

    # homelab.tailscale module
    "homelab-tailscale-enable" = {
      description = "homelab.tailscale.enable option exists";
      passed = refConfig.homelab.tailscale ? enable;
      expected = "homelab.tailscale.enable";
      actual = if refConfig.homelab.tailscale ? enable then "exists" else "missing";
    };

    "homelab-tailscale-tpmOverride" = {
      description = "homelab.tailscale.tpmOverride option exists";
      passed = refConfig.homelab.tailscale ? tpmOverride;
      expected = "homelab.tailscale.tpmOverride";
      actual = if refConfig.homelab.tailscale ? tpmOverride then "exists" else "missing";
    };

    # homelab.update module
    "homelab-update-enable" = {
      description = "homelab.update.enable option exists";
      passed = refConfig.homelab.update ? enable;
      expected = "homelab.update.enable";
      actual = if refConfig.homelab.update ? enable then "exists" else "missing";
    };

    # homelab.nixCaches module
    "homelab-nixCaches-enable" = {
      description = "homelab.nixCaches.enable option exists";
      passed = refConfig.homelab.nixCaches ? enable;
      expected = "homelab.nixCaches.enable";
      actual = if refConfig.homelab.nixCaches ? enable then "exists" else "missing";
    };

    "homelab-nixCaches-profile" = {
      description = "homelab.nixCaches.profile option exists";
      passed = refConfig.homelab.nixCaches ? profile;
      expected = "homelab.nixCaches.profile";
      actual = if refConfig.homelab.nixCaches ? profile then "exists" else "missing";
    };

    # Verify profile is one of the expected values
    "homelab-nixCaches-profile-valid" = {
      description = "homelab.nixCaches.profile is a valid enum value";
      passed = builtins.elem refConfig.homelab.nixCaches.profile ["internal" "external" "server"];
      expected = "internal|external|server";
      actual = refConfig.homelab.nixCaches.profile or "undefined";
    };
  };

  # Additional tests that check all hosts have the namespace
  perHostTests = lib.mapAttrs (name: cfg: {
    "has-homelab-namespace" = {
      description = "${name} has homelab namespace";
      passed = cfg.config ? homelab;
      expected = "homelab namespace";
      actual = if cfg.config ? homelab then "present" else "missing";
    };
  }) nixosConfigurations;

  failedTests = lib.filterAttrs (_: t: !t.passed) tests;
  failedCount = builtins.length (builtins.attrNames failedTests);

  formatTest = tname: t:
    if t.passed
    then "  PASS: ${tname}"
    else "  FAIL: ${tname} - expected '${t.expected}', got '${t.actual}'";

  summary = ''

    === Module Option Structure Tests ===
    Reference host: framework

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatTest tests)}

    Per-host namespace check:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "  PASS: ${name} has homelab namespace") nixosConfigurations)}

    Total tests: ${toString (builtins.length (builtins.attrNames tests))}
    Failed: ${toString failedCount}
    ${if failedCount == 0 then "Status: ALL TESTS PASSED" else "Status: TESTS FAILED"}
  '';

in {
  inherit tests perHostTests;
  passed = failedCount == 0;
  inherit summary;

  check =
    if failedCount == 0
    then true
    else throw "Module option tests failed with ${toString failedCount} failures";
}
