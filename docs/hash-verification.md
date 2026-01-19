# Hash-Based Configuration Verification

**Last Updated**: 2026-01-19

## Overview

NixOS's deterministic build model means configuration drift detection reduces to comparing derivation hashes. If two configurations produce identical `system.build.toplevel` store paths, they are functionally equivalent - no deployment differences exist.

This repo uses hash comparison instead of complex test suites because:
- Identical hashes = identical systems (cryptographic guarantee)
- No false positives from test logic bugs
- Simpler to maintain
- Faster to run

## Quick Start

```bash
# Capture current hashes as baseline
./scripts/hash-capture.sh

# Capture only NixOS or only Home Manager baselines
./scripts/hash-capture.sh --nixos-only
./scripts/hash-capture.sh --home-only

# After making changes, compare against baseline
./scripts/hash-compare.sh

# Summary only (skip nix-diff details)
./scripts/hash-compare.sh --summary

# Check specific host
./scripts/hash-compare.sh framework

# Check only NixOS or only Home Manager drift
./scripts/hash-compare.sh --nixos-only --summary
./scripts/hash-compare.sh --home-only --summary
```

For stabilisation patterns and ordering tiers, see `docs/stabilisation.md`.

## How It Works

### Hash Capture (`scripts/hash-capture.sh`)

Iterates over all `nixosConfigurations` and `homeConfigurations` in the flake, evaluates their toplevel derivation path, and stores it in `hashes/`:

```
hashes/
├── nixos-epimetheus.txt    # /nix/store/xxx-nixos-system-epimetheus-...
├── nixos-framework.txt
├── home-caddy.txt          # /nix/store/yyy-home-manager-generation
└── ...
```

### Hash Compare (`scripts/hash-compare.sh`)

For each stored hash:
1. Evaluates the current derivation path
2. Compares against the stored baseline
3. If different: runs `nix-diff` to show exactly what changed
4. Reports summary at the end

**Important**: The script does NOT bail on first error. It processes ALL hosts and reports ALL drift.

## Interpreting Results

### MATCH
```
  MATCH: nixos-framework
```
Hash unchanged. Your refactoring produced no functional changes to this host.

### DRIFT
```
  DRIFT: nixos-framework

--- nixos-framework ---
These two derivations differ because:
  * The input derivation /nix/store/xxx.drv differs
    * The value of environment variable "HOME" differs
      - old: "/homeless-shelter"
      + new: "/home/abl030"
```
Configuration changed. The nix-diff output shows the root cause.

## Common Scenarios

### Pure Refactoring
```bash
# Make structural changes (move modules, rename options)
./scripts/hash-compare.sh
# All MATCH = pure refactor, safe to merge
```

### Intentional Changes
```bash
# Add a new package, change a setting
./scripts/hash-compare.sh
# DRIFT detected - review nix-diff output
# If changes are expected:
./scripts/hash-capture.sh  # Update baselines
```

### Catching Regressions
```bash
# Refactoring that accidentally changes behavior
./scripts/hash-compare.sh
# DRIFT on hosts you didn't intend to change
# nix-diff shows what went wrong
```

## Integration

### Nightly CI (`rolling_flake_update.sh`)
After successful builds, the nightly update script:
1. Runs `./scripts/hash-capture.sh --quiet`
2. Commits updated hashes alongside `flake.lock`

This means baselines always reflect "last successful nightly build state".

### Local Development
During development, you might see DRIFT because:
- You haven't captured baselines yet
- Your changes intentionally modify configs

This is expected. Run `hash-capture.sh` when you want to establish a new baseline.

## Why Not Traditional Tests?

The previous test suite had 9 tests validating various aspects:
- Schema validation
- Module options existence
- SSH trust configuration
- etc.

These tests were:
- **Redundant**: If the flake evaluates, the config is valid
- **Fragile**: Test logic could have bugs
- **Incomplete**: Couldn't catch all possible regressions

Hash comparison is:
- **Complete**: Catches ANY change to the final system
- **Simple**: Just string comparison
- **Reliable**: Uses Nix's own guarantees

## Files

| File | Purpose |
|------|---------|
| `scripts/hash-capture.sh` | Capture current hashes |
| `scripts/hash-compare.sh` | Compare against baselines |
| `hashes/*.txt` | Stored baseline hashes |

## Troubleshooting

### "No baseline hashes found"
Run `./scripts/hash-capture.sh` to create initial baselines.

### All hosts show DRIFT after flake.lock update
This is expected. Input changes propagate to all derivations. Run `hash-capture.sh` to update baselines.

### nix-diff shows massive output
The diff might be deep in the dependency tree. Look for the first divergence point - that's usually the root cause.

### Evaluation errors
If a host fails to evaluate, it's reported as an error but other hosts continue processing. Fix the evaluation error first.
