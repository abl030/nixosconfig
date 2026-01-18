# Test: SSH Cross-Host Trust
# ==========================
# Verifies that SSH known_hosts generation works correctly.
# Each host should have all other fleet members in its known_hosts.
# Run with: nix eval .#tests.ssh-trust --apply 'x: x.summary'
#
{ nixosConfigurations, hosts, lib }:
let
  # Filter out special entries
  hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;

  # Hosts with public keys (can be in known_hosts)
  hostsWithKeys = lib.filterAttrs (_: host: host ? publicKey) hostEntries;

  testHost = name: _:
    let
      cfg = nixosConfigurations.${name}.config;
      knownHosts = cfg.programs.ssh.knownHosts or {};

      # Other hosts that should be in this host's known_hosts
      expectedHosts = lib.filterAttrs (n: _: n != name) hostsWithKeys;

      # Check each expected host
      hostChecks = lib.mapAttrs (otherName: otherHost:
        let
          entryName = "homelab-${otherName}";
          entry = knownHosts.${entryName} or null;
        in {
          present = entry != null;
          publicKeyMatch =
            if entry != null
            then (entry.publicKey or "") == otherHost.publicKey
            else false;
          hostNamesIncluded =
            if entry != null
            then
              builtins.elem otherHost.hostname (entry.hostNames or []) &&
              builtins.elem otherHost.sshAlias (entry.hostNames or [])
            else false;
        }
      ) expectedHosts;

      tests = {
        # Self should NOT be in known_hosts
        "no-self-reference" = {
          description = "host does not have itself in known_hosts";
          passed = !(knownHosts ? "homelab-${name}");
          expected = "no homelab-${name} entry";
          actual = if knownHosts ? "homelab-${name}" then "self-reference exists" else "no self-reference";
        };

        # All other hosts should be present
        "all-hosts-present" = {
          description = "all other fleet hosts are in known_hosts";
          passed = lib.all (c: c.present) (builtins.attrValues hostChecks);
          expected = "all ${toString (builtins.length (builtins.attrNames expectedHosts))} hosts present";
          actual =
            let presentCount = lib.count (c: c.present) (builtins.attrValues hostChecks);
            in "${toString presentCount}/${toString (builtins.length (builtins.attrNames expectedHosts))} present";
        };

        # Public keys should match
        "public-keys-match" = {
          description = "all known_hosts entries have correct public keys";
          passed = lib.all (c: c.publicKeyMatch) (builtins.attrValues hostChecks);
          expected = "all public keys match hosts.nix";
          actual =
            let matchCount = lib.count (c: c.publicKeyMatch) (builtins.attrValues hostChecks);
            in "${toString matchCount}/${toString (builtins.length (builtins.attrNames expectedHosts))} match";
        };

        # Host names and aliases should be included
        "hostnames-and-aliases" = {
          description = "known_hosts entries include hostname and sshAlias";
          passed = lib.all (c: c.hostNamesIncluded) (builtins.attrValues hostChecks);
          expected = "hostname and sshAlias in hostNames for all";
          actual =
            let count = lib.count (c: c.hostNamesIncluded) (builtins.attrValues hostChecks);
            in "${toString count}/${toString (builtins.length (builtins.attrNames expectedHosts))} have both";
        };
      };

      failedTests = lib.filterAttrs (_: t: !t.passed) tests;
    in {
      inherit name tests hostChecks;
      passed = builtins.length (builtins.attrNames failedTests) == 0;
      failedCount = builtins.length (builtins.attrNames failedTests);
    };

  results = lib.mapAttrs testHost nixosConfigurations;
  totalFailures = lib.foldl' (acc: r: acc + r.failedCount) 0 (builtins.attrValues results);

  formatResult = name: result:
    let
      testLines = lib.mapAttrsToList (tname: t:
        if t.passed
        then "    PASS: ${tname}"
        else "    FAIL: ${tname} - expected '${t.expected}', got '${t.actual}'"
      ) result.tests;
    in "  ${name}:\n${lib.concatStringsSep "\n" testLines}";

  summary = ''

    === SSH Cross-Host Trust Tests ===
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatResult results)}

    Hosts tested: ${toString (builtins.length (builtins.attrNames results))}
    Total failures: ${toString totalFailures}
    ${if totalFailures == 0 then "Status: ALL TESTS PASSED" else "Status: TESTS FAILED"}
  '';

in {
  inherit results;
  passed = totalFailures == 0;
  inherit summary;

  check =
    if totalFailures == 0
    then true
    else throw "SSH trust tests failed with ${toString totalFailures} failures";
}
