# NixOS Configuration Test Suite

This directory contains a comprehensive test suite for validating the NixOS configuration repository before and after refactoring.

## Quick Start

```bash
# Run all tests
./tests/run-tests.sh

# Update snapshot baselines (after intentional changes)
./tests/update-baselines.sh

# Inspect what changed after a config modification
./tests/inspect-changes.sh

# Compare a specific config value across hosts
./tests/inspect-config.sh --compare homelab.ssh.secure
```

## Test Categories

### Standalone Tests (No Flake Context Required)

These tests can run quickly without evaluating the full flake:

| Test | File | Description |
|------|------|-------------|
| **hosts-schema** | `hosts-schema.nix` | Validates hosts.nix structure |
| **tofu-consistency** | `tofu-consistency.nix` | Validates Proxmox/OpenTofu config |
| **vm-safety** | `vm-safety.sh` | Verifies VM protection mechanisms |

### Flake-Dependent Tests

These tests evaluate the full NixOS configurations:

| Test | File | Description |
|------|------|-------------|
| **special-args** | `special-args.nix` | Verifies factory pattern injection |
| **base-profile** | `base-profile.nix` | Checks base profile application |
| **ssh-trust** | `ssh-trust.nix` | Validates SSH known_hosts generation |
| **module-options** | `module-options.nix` | Ensures module options exist |
| **sops-paths** | `sops-paths.nix` | Checks secret file paths |
| **snapshots** | `snapshots.nix` | Compares derivation baselines |

---

## Detailed Test Descriptions

### 1. hosts-schema

**Purpose:** Validates that all host entries in `hosts.nix` conform to the expected schema.

**What it checks:**
- Required fields present for each host type (NixOS vs HM-only)
- Public key format validity (must start with `ssh-ed25519`)
- `authorizedKeys` is a list
- Proxmox configuration has required fields (vmid, cores, memory, disk)

**Run individually:**
```bash
nix-instantiate --eval tests/hosts-schema.nix --strict -A summary
nix-instantiate --eval tests/hosts-schema.nix --strict -A check
```

**Example output:**
```
=== hosts.nix Schema Validation ===
  PASS: caddy (HM-only)
  PASS: dev (NixOS)
  PASS: framework (NixOS)
  ...
Status: ALL TESTS PASSED
```

---

### 2. tofu-consistency

**Purpose:** Validates OpenTofu/Terranix configuration consistency.

**What it checks:**
- `_proxmox` global config has required fields (host, node, defaultStorage, templateVmid)
- All VMIDs are unique (no conflicts)
- Managed hosts have valid proxmox specs (vmid in range, positive cores, reasonable memory)
- Readonly hosts are correctly excluded from management

**Run individually:**
```bash
nix-instantiate --eval tests/tofu-consistency.nix --strict -A summary \
  --arg hosts 'import ./hosts.nix' \
  --arg lib 'import <nixpkgs/lib>'
```

**Example output:**
```
=== OpenTofu/Terranix Consistency Tests ===

Proxmox Global Configuration:
  PASS: has-host (192.168.1.12)
  PASS: has-node (prom)
  ...

VMID Uniqueness:
  PASS: All VMIDs are unique

Managed Hosts:
  dev: PASS (all checks)
  sandbox: PASS (all checks)
  ...
```

---

### 3. vm-safety

**Purpose:** Verifies that production VMs are protected from accidental destruction.

**What it checks:**
- `proxmox-ops.sh` wrapper exists and is executable
- Readonly VMIDs can be extracted from hosts.nix
- No VMID appears in both readonly and managed lists
- Wrapper script has safety check functions

**Run individually:**
```bash
./tests/vm-safety.sh
```

**Example output:**
```
=== VM Safety Invariant Tests ===

Test: proxmox-ops.sh exists and is executable... PASS
Test: Can extract readonly VMIDs from hosts.nix... PASS
Test: Managed VMIDs are not marked readonly... PASS
...
```

---

### 4. special-args

**Purpose:** Verifies that `nix/lib.nix` factory correctly injects special arguments to all modules.

**What it checks:**
- `networking.hostName` matches `hosts.nix` entry
- User from `hostConfig.user` is created
- SSH known_hosts contains fleet members (from `allHosts`)
- Nix flakes are enabled (verifies `hostConfig` access works)

**Run individually:**
```bash
nix eval --impure --expr '
  let
    flake = builtins.getFlake "path:/home/abl030/nixosconfig";
    pkgs = import <nixpkgs> {};
    test = import ./tests/special-args.nix {
      inherit (flake) nixosConfigurations homeConfigurations;
      hosts = import ./hosts.nix;
    };
  in test.summary
'
```

---

### 5. base-profile

**Purpose:** Verifies that `modules/nixos/profiles/base.nix` applies correctly to all NixOS hosts.

**What it checks:**
- Hostname set from `hostConfig.hostname`
- User created with correct home directory
- Nix flakes and nix-command enabled
- SSH server enabled
- Tailscale enabled
- Timezone set to Australia/Perth
- Git installed in system packages

**Run individually:**
```bash
nix eval --impure --expr '
  let
    flake = builtins.getFlake "path:/home/abl030/nixosconfig";
    pkgs = import <nixpkgs> {};
    test = import ./tests/base-profile.nix {
      inherit (flake) nixosConfigurations;
      hosts = import ./hosts.nix;
      lib = pkgs.lib;
    };
  in test.summary
'
```

---

### 6. ssh-trust

**Purpose:** Validates SSH known_hosts generation for fleet-wide trust.

**What it checks:**
- Each host has all OTHER fleet members in known_hosts (not self)
- Public keys match hosts.nix entries
- Both hostname and sshAlias are in hostNames list

**Run individually:**
```bash
nix eval --impure --expr '
  let
    flake = builtins.getFlake "path:/home/abl030/nixosconfig";
    pkgs = import <nixpkgs> {};
    test = import ./tests/ssh-trust.nix {
      inherit (flake) nixosConfigurations;
      hosts = import ./hosts.nix;
      lib = pkgs.lib;
    };
  in test.summary
'
```

---

### 7. module-options

**Purpose:** Ensures custom module options exist and have expected structure.

**What it checks:**
- `homelab` namespace exists
- `homelab.ssh.*` options exist (enable, secure, deployIdentity)
- `homelab.tailscale.*` options exist (enable, tpmOverride)
- `homelab.update.enable` exists
- `homelab.nixCaches.*` options exist (enable, profile)
- Cache profile is valid enum value (internal|external|server)

**Run individually:**
```bash
nix eval --impure --expr '
  let
    flake = builtins.getFlake "path:/home/abl030/nixosconfig";
    pkgs = import <nixpkgs> {};
    test = import ./tests/module-options.nix {
      inherit (flake) nixosConfigurations;
      lib = pkgs.lib;
    };
  in test.summary
'
```

---

### 8. sops-paths

**Purpose:** Verifies that all referenced secret files exist.

**What it checks:**
- All `sopsFile` paths in `sops.secrets` resolve to existing files
- Reports which hosts have secrets and how many

**Run individually:**
```bash
nix eval --impure --expr '
  let
    flake = builtins.getFlake "path:/home/abl030/nixosconfig";
    pkgs = import <nixpkgs> {};
    test = import ./tests/sops-paths.nix {
      inherit (flake) nixosConfigurations;
      lib = pkgs.lib;
      flakeRoot = /home/abl030/nixosconfig;
    };
  in test.summary
'
```

**Example output:**
```
=== Sops Secret Path Tests ===

  dev: 1 secrets, all files exist
  epimetheus: 3 secrets, all files exist
  framework: 1 secrets, all files exist
  sandbox: no sops secrets configured
  ...

Status: ALL TESTS PASSED
```

---

### 9. snapshots

**Purpose:** Compares current derivation paths against stored baselines to detect configuration drift.

**What it checks:**
- NixOS system toplevel derivation paths match baselines
- Home Manager activation package paths match baselines

**States:**
- `MATCH` - Derivation unchanged from baseline
- `CHANGED` - Derivation differs (refactoring may have changed output)
- `NO-BASELINE` - No baseline file exists yet

**Run individually:**
```bash
# Check status
nix eval .#nixosConfigurations.framework.config.system.build.toplevel

# Compare to baseline
cat tests/baselines/nixos-framework.txt
```

**Updating baselines:**
```bash
./tests/update-baselines.sh
```

---

## Directory Structure

```
tests/
├── README.md                 # This file
├── run-tests.sh              # Main test runner
├── update-baselines.sh       # Baseline update script
├── inspect-changes.sh        # Show what changed vs baseline
├── inspect-config.sh         # Query/compare config values
├── default.nix               # Test index (for flake integration)
├── baselines/                # Snapshot baseline files
│   ├── nixos-*.txt           # NixOS system derivation paths
│   └── home-*.txt            # Home Manager activation paths
├── hosts-schema.nix          # Schema validation test
├── special-args.nix          # Special arguments injection test
├── base-profile.nix          # Base profile application test
├── ssh-trust.nix             # SSH cross-host trust test
├── module-options.nix        # Module option structure test
├── snapshots.nix             # Derivation snapshot test
├── tofu-consistency.nix      # OpenTofu consistency test
├── sops-paths.nix            # Sops secret path test
└── vm-safety.sh              # VM safety invariant test
```

---

## Inspection Tools

### inspect-changes.sh

Shows what changed between baseline and current configuration.

```bash
# Summary of all changes
./tests/inspect-changes.sh

# Changes for specific host
./tests/inspect-changes.sh framework

# Detailed diff with nvd
./tests/inspect-changes.sh framework --diff

# Show package changes
./tests/inspect-changes.sh framework --packages

# Show service changes
./tests/inspect-changes.sh framework --services

# Show generated file changes
./tests/inspect-changes.sh framework --files
```

### inspect-config.sh

Query and compare configuration values across hosts.

```bash
# Get single value
./tests/inspect-config.sh framework networking.hostName

# Get value from all hosts
./tests/inspect-config.sh --all homelab.ssh.enable

# Compare across hosts (highlights differences)
./tests/inspect-config.sh --compare homelab.nixCaches.profile

# Inspect SSH known hosts
./tests/inspect-config.sh --known-hosts framework

# List system packages
./tests/inspect-config.sh --packages framework
```

Common option paths:
- `networking.hostName`
- `homelab.ssh.enable`, `homelab.ssh.secure`
- `homelab.tailscale.enable`
- `homelab.nixCaches.profile`
- `services.openssh.enable`
- `services.tailscale.enable`

---

## Integration with Refactoring Workflow

### Before Refactoring

1. Run the full test suite to establish baseline:
   ```bash
   ./tests/run-tests.sh
   ```

2. Update snapshot baselines:
   ```bash
   ./tests/update-baselines.sh
   ```

3. Commit the baselines:
   ```bash
   git add tests/baselines/
   git commit -m "test: update baselines before refactoring"
   ```

### During Refactoring

1. Run tests frequently to catch regressions:
   ```bash
   ./tests/run-tests.sh
   ```

2. If snapshots fail, investigate:
   - Was this change intentional?
   - Did the refactoring unexpectedly change outputs?

3. Update baselines only after confirming changes are correct:
   ```bash
   ./tests/update-baselines.sh
   ```

### After Refactoring

1. Run full test suite:
   ```bash
   ./tests/run-tests.sh
   ```

2. Verify all tests pass

3. Commit final baselines

---

## Adding New Tests

### Nix-based Test Template

```nix
# tests/my-new-test.nix
{ nixosConfigurations, lib, ... }:
let
  tests = {
    "test-name" = {
      description = "What this tests";
      passed = true; # Your test logic here
      expected = "expected value";
      actual = "actual value";
    };
  };

  failedTests = lib.filterAttrs (_: t: !t.passed) tests;
  failedCount = builtins.length (builtins.attrNames failedTests);

in {
  inherit tests;
  passed = failedCount == 0;
  summary = "..."; # Human-readable output
  check = if failedCount == 0 then true else throw "Tests failed";
}
```

### Shell-based Test Template

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== My New Test ==="

# Test logic here
if [[ condition ]]; then
    echo "PASS: description"
else
    echo "FAIL: description"
    exit 1
fi

echo "All tests passed."
```

---

## Troubleshooting

### Tests Timeout

The flake-dependent tests use a 120-second timeout. If tests are timing out:
- Check if the flake is evaluating correctly: `nix flake check`
- Try running the specific test directly (see individual test sections)

### Snapshot Mismatches

If snapshots show CHANGED but you didn't modify the configuration:
- The flake inputs may have updated
- Check `git diff flake.lock` for input changes
- Re-run `./tests/update-baselines.sh` if input updates are expected

### "Cannot evaluate flake" Error

Ensure you're in the repository root and the flake is valid:
```bash
cd /home/abl030/nixosconfig
nix flake check
```

---

## Future Improvements

When integrating with `flake.nix`, add to checks:

```nix
checks.x86_64-linux = {
  hosts-schema = tests.hosts-schema.check;
  special-args = tests.special-args.check;
  # ... etc
};
```

This will make `nix flake check` run all tests automatically.
