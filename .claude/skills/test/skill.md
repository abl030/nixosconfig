---
name: test
description: Run the NixOS configuration test suite to validate configs before/after refactoring
---

# Test Suite Skill

Run the comprehensive test suite to validate NixOS configurations. Use this before and after refactoring to catch regressions.

## Quick Commands

### Run All Tests

```bash
./tests/run-tests.sh
```

This runs all 9 tests and reports pass/fail status.

### Inspect What Changed

After modifying configuration, see what actually changed:

```bash
# Summary of all changes
./tests/inspect-changes.sh

# Detailed diff for a specific host
./tests/inspect-changes.sh framework --diff

# Show package/service changes
./tests/inspect-changes.sh framework --packages
./tests/inspect-changes.sh framework --services
```

### Compare Config Values

Query specific configuration values across hosts:

```bash
# Compare a value across all hosts
./tests/inspect-config.sh --compare homelab.nixCaches.profile

# Get value for all hosts
./tests/inspect-config.sh --all homelab.ssh.secure

# Get single host value
./tests/inspect-config.sh framework networking.hostName
```

### Update Baselines

After intentional configuration changes, update the snapshot baselines:

```bash
./tests/update-baselines.sh
```

## Test Summary

| # | Test | Type | What It Validates |
|---|------|------|-------------------|
| 1 | **hosts-schema** | Standalone | hosts.nix structure (required fields, key format) |
| 2 | **tofu-consistency** | Standalone | Proxmox/OpenTofu config, VMID uniqueness |
| 3 | **vm-safety** | Shell | VM protection (readonly flags, wrapper safety) |
| 4 | **special-args** | Flake | Factory pattern injection (hostname, hostConfig, allHosts) |
| 5 | **base-profile** | Flake | Base profile application (user, flakes, ssh, tailscale) |
| 6 | **ssh-trust** | Flake | SSH known_hosts generation (fleet trust) |
| 7 | **module-options** | Flake | homelab.* module options exist |
| 8 | **sops-paths** | Flake | Secret file paths exist |
| 9 | **snapshots** | Flake | Derivation paths match baselines |

## Interpreting Results

### All Tests Pass
```
PASS: hosts-schema
PASS: tofu-consistency
...
All tests passed!
```
Configuration is valid. Safe to deploy.

### Schema Failures
```
FAIL: hosts-schema
      missing required fields: publicKey
```
Fix: Check hosts.nix for the reported host. Add missing fields.

### Snapshot Changes
```
FAIL: snapshots
      3 changed
```
This means derivation outputs differ from baseline. Either:
- **Intentional**: Run `./tests/update-baselines.sh` to update
- **Unintentional**: Investigate what caused the change

### SSH Trust Failures
```
FAIL: ssh-trust
      expected all 8 hosts present, got 7/8 present
```
A host is missing from known_hosts. Check:
- Does the host have a `publicKey` in hosts.nix?
- Is the SSH module generating known_hosts correctly?

## Refactoring Workflow

### Before Refactoring
```bash
# 1. Run tests to confirm everything works
./tests/run-tests.sh

# 2. Update baselines to current state
./tests/update-baselines.sh

# 3. Commit baselines
git add tests/baselines/
git commit -m "test: baseline before refactoring"
```

### During Refactoring
```bash
# Run frequently to catch regressions
./tests/run-tests.sh
```

### After Refactoring
```bash
# 1. Run full suite
./tests/run-tests.sh

# 2. If snapshots changed intentionally, update baselines
./tests/update-baselines.sh

# 3. Commit
git add tests/
git commit -m "test: update baselines after refactoring"
```

## Individual Test Commands

### Standalone Tests (fast, no flake evaluation)

```bash
# Schema validation
nix-instantiate --eval tests/hosts-schema.nix --strict -A summary

# OpenTofu consistency
nix-instantiate --eval tests/tofu-consistency.nix --strict -A summary \
  --arg hosts 'import ./hosts.nix' \
  --arg lib 'import <nixpkgs/lib>'

# VM safety
./tests/vm-safety.sh
```

### Flake-Dependent Tests (slower, full evaluation)

```bash
# Special args injection
nix eval --impure --expr '
  let flake = builtins.getFlake "path:.";
      pkgs = import <nixpkgs> {};
      test = import ./tests/special-args.nix {
        inherit (flake) nixosConfigurations homeConfigurations;
        hosts = import ./hosts.nix;
      };
  in test.summary
'

# Similar pattern for: base-profile, ssh-trust, module-options, sops-paths
```

### Snapshot Comparison

```bash
# Check a specific host
baseline=$(cat tests/baselines/nixos-framework.txt)
current=$(nix eval --raw ".#nixosConfigurations.framework.config.system.build.toplevel")
[[ "$baseline" == "$current" ]] && echo "MATCH" || echo "CHANGED"
```

## Files

| File | Purpose |
|------|---------|
| `tests/run-tests.sh` | Main test runner |
| `tests/update-baselines.sh` | Update snapshot baselines |
| `tests/inspect-changes.sh` | Show what changed vs baseline |
| `tests/inspect-config.sh` | Query/compare config values |
| `tests/README.md` | Full documentation |
| `tests/baselines/` | Stored derivation paths |
| `tests/*.nix` | Individual test implementations |
