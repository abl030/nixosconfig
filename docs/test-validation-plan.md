# Test Validation Plan

Systematically verify each test catches errors as expected.

## Test Validation Checklist

| # | Test | Error 1 | Error 2 | Status |
|---|------|---------|---------|--------|
| 1 | hosts-schema | [x] Missing publicKey field | [x] Invalid publicKey format | PASS |
| 2 | tofu-consistency | [x] Duplicate VMID | [x] Missing cores field | PASS |
| 3 | vm-safety | [x] proxmox-ops.sh not executable | [x] Missing safety functions | PASS |
| 4 | special-args | [x] Wrong hostname (mkForce) | [x] check function throws | PASS |
| 5 | base-profile | [x] Wrong timezone | [x] Missing git package | PASS |
| 6 | ssh-trust | [x] Hardcoded wrong public key | [x] Missing sshAlias in hostNames | PASS |
| 7 | module-options | [x] Missing option (build fails) | [x] Invalid enum (type check fails) | PASS |
| 8 | sops-paths | [x] Wrong sopsFile path | [x] Renamed secret file | PASS |
| 9 | snapshots | [x] Modified baseline file | [x] Added env variable to config | PASS |

## Validation Complete

All 9 tests have been validated with at least 2 intentional errors each.

### Summary of Error Types Detected

1. **hosts-schema**: Catches missing fields and invalid format strings
2. **tofu-consistency**: Catches duplicate VMIDs and missing Proxmox config fields
3. **vm-safety**: Catches missing/non-executable wrapper script and missing safety functions
4. **special-args**: Catches hostname mismatches and properly throws on failure
5. **base-profile**: Catches timezone changes and missing packages
6. **ssh-trust**: Catches wrong public keys and missing host aliases
7. **module-options**: Module system prevents builds with missing options or invalid enums
8. **sops-paths**: Catches missing or incorrectly-referenced secret files
9. **snapshots**: Catches any derivation changes via baseline comparison

### Fixes Applied During Validation

1. **hosts-schema.nix**: Added existence checks before accessing `host.publicKey` to prevent crashes on missing fields
2. **tofu-consistency.nix**: Added existence checks for `px.vmid`, `px.cores`, `px.memory` before validation

### Notes

- Module-options test relies on NixOS module system type checking for enum validation
- Some tests catch errors at different layers (Nix evaluation vs. test logic)

### Snapshot Baseline Management

Baselines are automatically maintained by the nightly `rolling_flake_update.sh` script:

1. **Nightly run**: flake.lock updates → builds verified → baselines regenerated → all committed together
2. **During development**: Snapshot tests may show "CHANGED" for work-in-progress (expected)
3. **After nightly**: Baselines sync back to match the latest successful build

This means baselines represent "last successful nightly build state" - a meaningful reference point rather than ad-hoc commits.
