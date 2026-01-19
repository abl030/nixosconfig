---
name: test-detail
description: Detailed information about individual tests and how to debug failures
---

# Individual Test Details

This skill provides in-depth information about each test, what it validates, and how to debug failures.

---

## 1. hosts-schema

**Type:** Standalone (no flake context)
**File:** `tests/hosts-schema.nix`
**Speed:** Fast (~1 second)

### What It Tests

- **Required fields** for each host type:
  - All hosts: `hostname`, `user`, `homeDirectory`, `publicKey`, `authorizedKeys`, `homeFile`, `sshAlias`
  - NixOS hosts (with `configurationFile`): all above + `configurationFile`
- **Public key format**: Must start with `ssh-ed25519 `
- **authorizedKeys**: Must be a list
- **Proxmox config** (if present): Must have `vmid`, `cores`, `memory`, `disk`

### Run Command

```bash
# Full summary
nix-instantiate --eval tests/hosts-schema.nix --strict -A summary

# Just pass/fail
nix-instantiate --eval tests/hosts-schema.nix --strict -A check
```

### Common Failures

**Missing required field:**
```
FAIL: my-host - missing required fields: publicKey sshAlias
```
Fix: Add the missing fields to the host entry in `hosts.nix`

**Invalid public key:**
```
FAIL: my-host - publicKey must start with 'ssh-ed25519 '
```
Fix: Ensure the key is an ed25519 key, not RSA or other type

---

## 2. tofu-consistency

**Type:** Standalone
**File:** `tests/tofu-consistency.nix`
**Speed:** Fast (~1 second)

### What It Tests

- **Proxmox global config** (`_proxmox`): has `host`, `node`, `defaultStorage`, `templateVmid`
- **VMID uniqueness**: No two hosts share the same VMID
- **Managed hosts** have valid specs:
  - `vmid` between 100-8999
  - `cores` > 0
  - `memory` between 512-128000 MB
  - `disk` defined

### Run Command

```bash
nix-instantiate --eval tests/tofu-consistency.nix --strict -A summary \
  --arg hosts 'import ./hosts.nix' \
  --arg lib 'import <nixpkgs/lib>'
```

### Common Failures

**Duplicate VMID:**
```
VMID Uniqueness:
  FAIL: Duplicate VMIDs: 110
```
Fix: Change one of the hosts to use a unique VMID

**Missing proxmox field:**
```
FAIL: has-disk - expected 'disk defined', got 'missing'
```
Fix: Add the `disk` field to the host's proxmox config

---

## 3. vm-safety

**Type:** Shell script
**File:** `tests/vm-safety.sh`
**Speed:** Fast (~2 seconds)

### What It Tests

- `proxmox-ops.sh` wrapper exists and is executable
- Readonly VMIDs can be extracted from hosts.nix
- No VMID appears in both readonly and managed lists
- Wrapper script contains safety check functions

### Run Command

```bash
./tests/vm-safety.sh
```

### Common Failures

**Wrapper missing:**
```
Test: proxmox-ops.sh exists and is executable... FAIL
```
Fix: Ensure `vms/proxmox-ops.sh` exists and has execute permissions

**VMID conflict:**
```
FAIL - VMID 104 is in both lists!
```
Fix: A VM cannot be both readonly and managed. Update `hosts.nix`

---

## 4. special-args

**Type:** Flake-dependent
**File:** `tests/special-args.nix`
**Speed:** Slow (~30-60 seconds, first run slower due to evaluation)

### What It Tests

Verifies that `nix/lib.nix` factory injects special arguments correctly:

- `hostname`: `networking.hostName` matches `hosts.nix`
- `hostConfig`: User from `hostConfig.user` exists
- `allHosts`: SSH known_hosts contains fleet members
- General: Nix flakes enabled (proves hostConfig access works)

### Run Command

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

### Common Failures

**Hostname mismatch:**
```
FAIL: hostname-set - expected 'framework', got 'nixos'
```
Fix: Check that `hostConfig.hostname` is being used in base profile

**User not created:**
```
FAIL: user-created - expected 'users.users.abl030 exists', got 'missing'
```
Fix: Check base profile user creation from `hostConfig.user`

---

## 5. base-profile

**Type:** Flake-dependent
**File:** `tests/base-profile.nix`
**Speed:** Slow

### What It Tests

Validates `modules/nixos/profiles/base.nix` applies to all hosts:

- Hostname set from `hostConfig.hostname`
- User created with correct home directory
- Nix flakes and nix-command enabled
- SSH server enabled
- Tailscale enabled
- Timezone set to Australia/Perth
- Git in system packages

### Run Command

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

### Common Failures

**Tailscale not enabled:**
```
FAIL: tailscale-enabled - expected 'true', got 'false'
```
Fix: Check that `homelab.tailscale.enable = lib.mkDefault true;` is in base profile

**Wrong timezone:**
```
FAIL: timezone-perth - expected 'Australia/Perth', got 'UTC'
```
Fix: A host is overriding the timezone. Check host-specific configuration

---

## 6. ssh-trust

**Type:** Flake-dependent
**File:** `tests/ssh-trust.nix`
**Speed:** Slow

### What It Tests

Validates SSH known_hosts generation for fleet-wide trust:

- Each host has all OTHER fleet members (not self)
- Public keys match hosts.nix entries
- Both hostname and sshAlias in hostNames list

### Run Command

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

### Common Failures

**Missing hosts:**
```
FAIL: all-hosts-present - expected 'all 8 hosts present', got '7/8 present'
```
Fix: Check which host is missing. Does it have a `publicKey` in hosts.nix?

**Self-reference:**
```
FAIL: no-self-reference - expected 'no homelab-framework entry', got 'self-reference exists'
```
Fix: The SSH module is incorrectly including the host itself. Check filtering logic

---

## 7. module-options

**Type:** Flake-dependent
**File:** `tests/module-options.nix`
**Speed:** Slow

### What It Tests

Ensures custom module options exist:

- `homelab` namespace exists
- `homelab.ssh.*` options (enable, secure, deployIdentity)
- `homelab.tailscale.*` options (enable, tpmOverride)
- `homelab.update.enable`
- `homelab.nixCaches.*` options (enable, profile)
- Cache profile is valid enum

### Run Command

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

### Common Failures

**Missing option:**
```
FAIL: homelab-ssh-deployIdentity - expected 'homelab.ssh.deployIdentity', got 'missing'
```
Fix: Option was renamed or removed. Update the module or test

---

## 8. sops-paths

**Type:** Flake-dependent
**File:** `tests/sops-paths.nix`
**Speed:** Slow

### What It Tests

Verifies all referenced secret files exist:

- All `sopsFile` paths in `sops.secrets` resolve to real files
- Reports secret counts per host

### Run Command

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

### Common Failures

**Missing secret file:**
```
FAIL: framework - 1 secrets, MISSING: ssh_key_abl030
```
Fix: Create the missing secret file or update the secret configuration

---

## 9. snapshots

**Type:** Flake-dependent (shell-based comparison)
**File:** `tests/snapshots.nix` + baselines
**Speed:** Slow

### What It Tests

Compares current derivation paths against stored baselines:

- NixOS system toplevel paths
- Home Manager activation package paths

### States

- **MATCH**: Derivation unchanged (good)
- **CHANGED**: Derivation differs (investigate)
- **NO-BASELINE**: No baseline exists yet

### Run Command

```bash
# Via test runner
./tests/run-tests.sh

# Manual check for one host
baseline=$(cat tests/baselines/nixos-framework.txt)
current=$(nix eval --raw ".#nixosConfigurations.framework.config.system.build.toplevel")
[[ "$baseline" == "$current" ]] && echo "MATCH" || echo "CHANGED"
```

### Handling Changes

**During development:** Snapshot "CHANGED" is expected for WIP. Baselines auto-sync nightly.

**After nightly run:** If snapshots still show CHANGED, something unexpected changed:
1. Check `git diff` for what changed in configs
2. Check `git diff flake.lock` for input updates
3. Investigate which host(s) changed and why

**Manual update (rarely needed):**
```bash
./tests/update-baselines.sh
```

**Note:** Baselines are automatically updated by `rolling_flake_update.sh` after successful nightly builds.

### Debugging Derivation Differences

```bash
# Get the two derivations
old=$(cat tests/baselines/nixos-framework.txt)
new=$(nix eval --raw ".#nixosConfigurations.framework.config.system.build.toplevel")

# Compare with nix-diff (if available)
nix run nixpkgs#nix-diff -- "$old" "$new"

# Or use nvd
nix run nixpkgs#nvd -- diff "$old" "$new"
```

---

## Test Speed Reference

| Test | Approximate Time |
|------|------------------|
| hosts-schema | ~1s |
| tofu-consistency | ~1s |
| vm-safety | ~2s |
| special-args | ~30-60s (first run) |
| base-profile | ~30-60s |
| ssh-trust | ~30-60s |
| module-options | ~30-60s |
| sops-paths | ~30-60s |
| snapshots | ~60-120s |
| **Full suite** | **~3-5 minutes** |

Note: Flake-dependent tests share evaluation cache, so running them together is faster than running separately.
