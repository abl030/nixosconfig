# Test Suite Index
# ================
# Entry point for all tests. Can be imported from flake.nix.
#
# Usage from flake:
#   tests = import ./tests { inherit self pkgs lib; };
#
# Usage standalone:
#   nix eval .#tests.hosts-schema.summary
#   nix eval .#tests.special-args.summary
#
{ self, pkgs, lib }:
let
  hosts = import ../hosts.nix;
in {
  # Schema validation - can run standalone
  hosts-schema = import ./hosts-schema.nix { };

  # Special arguments injection - needs flake context
  special-args = import ./special-args.nix {
    inherit (self) nixosConfigurations homeConfigurations;
    inherit hosts;
  };

  # Base profile tests - needs flake context
  base-profile = import ./base-profile.nix {
    inherit (self) nixosConfigurations;
    inherit hosts lib;
  };

  # SSH trust tests - needs flake context
  ssh-trust = import ./ssh-trust.nix {
    inherit (self) nixosConfigurations;
    inherit hosts lib;
  };

  # Module options tests - needs flake context
  module-options = import ./module-options.nix {
    inherit (self) nixosConfigurations;
    inherit lib;
  };

  # Derivation snapshots - needs flake context
  snapshots = import ./snapshots.nix {
    inherit (self) nixosConfigurations homeConfigurations;
    inherit pkgs lib;
    baselinesDir = ./baselines;
  };

  # OpenTofu/Terranix consistency - needs hosts.nix
  tofu-consistency = import ./tofu-consistency.nix {
    inherit hosts lib;
  };

  # Sops secret paths - needs flake context
  sops-paths = import ./sops-paths.nix {
    inherit (self) nixosConfigurations;
    inherit lib;
    flakeRoot = ../.;
  };

  # Run all tests and return summary
  all = let
    testList = [
      { name = "hosts-schema"; test = self.tests.hosts-schema; }
      { name = "special-args"; test = self.tests.special-args; }
      { name = "base-profile"; test = self.tests.base-profile; }
      { name = "ssh-trust"; test = self.tests.ssh-trust; }
      { name = "module-options"; test = self.tests.module-options; }
      { name = "tofu-consistency"; test = self.tests.tofu-consistency; }
      { name = "sops-paths"; test = self.tests.sops-paths; }
    ];

    results = map (t: {
      inherit (t) name;
      passed = t.test.passed or false;
    }) testList;

    passedCount = lib.count (r: r.passed) results;
    totalCount = builtins.length results;
  in {
    inherit results;
    passed = passedCount == totalCount;
    summary = ''
      === Test Suite Summary ===
      ${lib.concatMapStringsSep "\n" (r: "  ${if r.passed then "PASS" else "FAIL"}: ${r.name}") results}

      Passed: ${toString passedCount}/${toString totalCount}
      ${if passedCount == totalCount then "Status: ALL TESTS PASSED" else "Status: SOME TESTS FAILED"}
    '';
  };
}
