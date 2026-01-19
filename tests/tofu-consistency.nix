# Test: OpenTofu/Terranix Consistency
# ====================================
# Verifies that Terranix would generate correct configs from hosts.nix.
# Run with: nix-instantiate --eval tests/tofu-consistency.nix --strict -A summary
#
{ hosts, lib }:
let
  # Filter out special entries (prefixed with _)
  hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;

  # Get proxmox config
  proxmoxConfig = hosts._proxmox or {};

  # Hosts that should be managed by OpenTofu (have proxmox config, not readonly)
  managedHosts = lib.filterAttrs (name: host:
    host ? proxmox && !(host.proxmox.readonly or false)
  ) hostEntries;

  # Hosts with proxmox config marked readonly (imported, not managed)
  readonlyHosts = lib.filterAttrs (name: host:
    host ? proxmox && (host.proxmox.readonly or false)
  ) hostEntries;

  # Validate a managed host's proxmox config
  validateManagedHost = name: host:
    let
      px = host.proxmox;
      tests = {
        "has-vmid" = {
          passed = px ? vmid;
          expected = "vmid defined";
          actual = if px ? vmid then "vmid=${toString px.vmid}" else "missing";
        };

        "has-cores" = {
          passed = px ? cores;
          expected = "cores defined";
          actual = if px ? cores then "cores=${toString px.cores}" else "missing";
        };

        "has-memory" = {
          passed = px ? memory;
          expected = "memory defined";
          actual = if px ? memory then "memory=${toString px.memory}" else "missing";
        };

        "has-disk" = {
          passed = px ? disk;
          expected = "disk defined";
          actual = if px ? disk then "disk=${px.disk}" else "missing";
        };

        "vmid-in-valid-range" = {
          passed = if px ? vmid then px.vmid >= 100 && px.vmid < 9000 else false;
          expected = "vmid between 100-8999";
          actual = if px ? vmid then "vmid=${toString px.vmid}" else "missing";
        };

        "cores-positive" = {
          passed = if px ? cores then px.cores > 0 else false;
          expected = "cores > 0";
          actual = if px ? cores then "cores=${toString px.cores}" else "missing";
        };

        "memory-reasonable" = {
          passed = if px ? memory then px.memory >= 512 && px.memory <= 128000 else false;
          expected = "memory 512-128000 MB";
          actual = if px ? memory then "memory=${toString px.memory}" else "missing";
        };
      };

      failedTests = lib.filterAttrs (_: t: !t.passed) tests;
    in {
      inherit name tests;
      passed = builtins.length (builtins.attrNames failedTests) == 0;
      failedCount = builtins.length (builtins.attrNames failedTests);
    };

  # VMID uniqueness check
  allVmids = lib.mapAttrsToList (name: host: {
    inherit name;
    vmid = host.proxmox.vmid;
  }) (lib.filterAttrs (_: host: host ? proxmox) hostEntries);

  vmidCounts = lib.foldl' (acc: item:
    acc // { ${toString item.vmid} = (acc.${toString item.vmid} or 0) + 1; }
  ) {} allVmids;

  duplicateVmids = lib.filterAttrs (_: count: count > 1) vmidCounts;
  hasNoDuplicates = builtins.length (builtins.attrNames duplicateVmids) == 0;

  # Validate proxmox global config
  proxmoxConfigTests = {
    "has-host" = {
      passed = proxmoxConfig ? host;
      expected = "_proxmox.host defined";
      actual = if proxmoxConfig ? host then proxmoxConfig.host else "missing";
    };

    "has-node" = {
      passed = proxmoxConfig ? node;
      expected = "_proxmox.node defined";
      actual = if proxmoxConfig ? node then proxmoxConfig.node else "missing";
    };

    "has-defaultStorage" = {
      passed = proxmoxConfig ? defaultStorage;
      expected = "_proxmox.defaultStorage defined";
      actual = if proxmoxConfig ? defaultStorage then proxmoxConfig.defaultStorage else "missing";
    };

    "has-templateVmid" = {
      passed = proxmoxConfig ? templateVmid;
      expected = "_proxmox.templateVmid defined";
      actual = if proxmoxConfig ? templateVmid then toString proxmoxConfig.templateVmid else "missing";
    };
  };

  managedResults = lib.mapAttrs validateManagedHost managedHosts;
  totalManagedFailures = lib.foldl' (acc: r: acc + r.failedCount) 0 (builtins.attrValues managedResults);
  proxmoxConfigFailures = builtins.length (builtins.attrNames (lib.filterAttrs (_: t: !t.passed) proxmoxConfigTests));

  formatManagedResult = name: result:
    let
      testLines = lib.mapAttrsToList (tname: t:
        if t.passed
        then "      PASS: ${tname}"
        else "      FAIL: ${tname} - expected '${t.expected}', got '${t.actual}'"
      ) result.tests;
    in "    ${name}:\n${lib.concatStringsSep "\n" testLines}";

  formatProxmoxTest = tname: t:
    if t.passed
    then "  PASS: ${tname} (${t.actual})"
    else "  FAIL: ${tname} - expected '${t.expected}', got '${t.actual}'";

  summary = ''

    === OpenTofu/Terranix Consistency Tests ===

    Proxmox Global Configuration:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList formatProxmoxTest proxmoxConfigTests)}

    VMID Uniqueness:
      ${if hasNoDuplicates then "PASS: All VMIDs are unique" else "FAIL: Duplicate VMIDs: ${toString (builtins.attrNames duplicateVmids)}"}

    Managed Hosts (would be created/updated by OpenTofu):
    ${if builtins.length (builtins.attrNames managedHosts) == 0
      then "  (none)"
      else lib.concatStringsSep "\n" (lib.mapAttrsToList formatManagedResult managedResults)}

    Readonly Hosts (excluded from OpenTofu management):
    ${if builtins.length (builtins.attrNames readonlyHosts) == 0
      then "  (none)"
      else lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "    ${name} (vmid=${toString hosts.${name}.proxmox.vmid})") readonlyHosts)}

    Summary:
      Managed hosts: ${toString (builtins.length (builtins.attrNames managedHosts))}
      Readonly hosts: ${toString (builtins.length (builtins.attrNames readonlyHosts))}
      Proxmox config failures: ${toString proxmoxConfigFailures}
      Managed host failures: ${toString totalManagedFailures}
      VMID conflicts: ${if hasNoDuplicates then "0" else toString (builtins.length (builtins.attrNames duplicateVmids))}

    ${if proxmoxConfigFailures == 0 && totalManagedFailures == 0 && hasNoDuplicates
      then "Status: ALL TESTS PASSED"
      else "Status: TESTS FAILED"}
  '';

  passed = proxmoxConfigFailures == 0 && totalManagedFailures == 0 && hasNoDuplicates;

in {
  inherit managedHosts readonlyHosts managedResults;
  proxmoxConfig = proxmoxConfigTests;
  vmidUnique = hasNoDuplicates;
  inherit passed summary;

  check =
    if passed
    then true
    else throw "OpenTofu consistency tests failed";
}
