# Test: Base Profile Application
# ===============================
# Verifies that modules/nixos/profiles/base.nix applies correctly to all hosts.
# Run with: nix eval .#tests.base-profile --apply 'x: x.summary'
#
{ nixosConfigurations, hosts, lib }:
let
  # Filter out special entries
  hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;

  # Only test NixOS hosts (those with configurationFile)
  nixosHosts = lib.filterAttrs (name: host: host ? configurationFile) hostEntries;

  testHost = name: _:
    let
      cfg = nixosConfigurations.${name}.config;
      hostEntry = hosts.${name};

      tests = {
        # Hostname from hostConfig
        "hostname-from-hostConfig" = {
          description = "networking.hostName set from hostConfig.hostname";
          passed = cfg.networking.hostName == hostEntry.hostname;
          expected = hostEntry.hostname;
          actual = cfg.networking.hostName;
        };

        # User creation
        "user-created" = {
          description = "user created from hostConfig.user";
          passed = cfg.users.users ? ${hostEntry.user};
          expected = hostEntry.user;
          actual = if cfg.users.users ? ${hostEntry.user} then hostEntry.user else "missing";
        };

        # User home directory
        "user-home-directory" = {
          description = "user home directory matches hostConfig";
          passed = cfg.users.users.${hostEntry.user}.home or "" == hostEntry.homeDirectory;
          expected = hostEntry.homeDirectory;
          actual = cfg.users.users.${hostEntry.user}.home or "not set";
        };

        # Nix flakes enabled
        "nix-flakes-enabled" = {
          description = "nix flakes experimental feature enabled";
          passed = builtins.elem "flakes" (cfg.nix.settings.experimental-features or []);
          expected = "flakes";
          actual = toString (cfg.nix.settings.experimental-features or []);
        };

        # Nix-command enabled
        "nix-command-enabled" = {
          description = "nix-command experimental feature enabled";
          passed = builtins.elem "nix-command" (cfg.nix.settings.experimental-features or []);
          expected = "nix-command";
          actual = toString (cfg.nix.settings.experimental-features or []);
        };

        # SSH server enabled
        "sshd-enabled" = {
          description = "SSH server enabled";
          passed = cfg.services.openssh.enable or false;
          expected = "true";
          actual = toString (cfg.services.openssh.enable or false);
        };

        # Tailscale enabled
        "tailscale-enabled" = {
          description = "Tailscale service enabled";
          passed = cfg.services.tailscale.enable or false;
          expected = "true";
          actual = toString (cfg.services.tailscale.enable or false);
        };

        # Timezone set to Australia/Perth
        "timezone-perth" = {
          description = "timezone set to Australia/Perth";
          passed = cfg.time.timeZone == "Australia/Perth";
          expected = "Australia/Perth";
          actual = cfg.time.timeZone or "not set";
        };

        # Git installed (from base profile packages)
        "git-installed" = {
          description = "git in system packages";
          passed = builtins.any (p: (p.pname or p.name or "") == "git") cfg.environment.systemPackages;
          expected = "git in systemPackages";
          actual = if builtins.any (p: (p.pname or p.name or "") == "git") cfg.environment.systemPackages then "present" else "missing";
        };
      };

      failedTests = lib.filterAttrs (_: t: !t.passed) tests;
    in {
      inherit name tests;
      passed = builtins.length (builtins.attrNames failedTests) == 0;
      failedCount = builtins.length (builtins.attrNames failedTests);
      failures = failedTests;
    };

  results = lib.mapAttrs testHost nixosHosts;
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

    === Base Profile Application Tests ===
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
    else throw "Base profile tests failed with ${toString totalFailures} failures";
}
