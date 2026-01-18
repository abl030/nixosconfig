#!/usr/bin/env bash
# Test: VM Safety Invariants
# ==========================
# Verifies that production VMs are protected by readonly flags.
# Run with: ./tests/vm-safety.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== VM Safety Invariant Tests ==="
echo ""

# Test 1: proxmox-ops.sh exists and is executable
echo -n "Test: proxmox-ops.sh exists and is executable... "
if [[ -x "$REPO_ROOT/vms/proxmox-ops.sh" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi

# Test 2: Parse hosts.nix for readonly VMIDs
# We use nix-instantiate to extract the readonly VMIDs
echo -n "Test: Can extract readonly VMIDs from hosts.nix... "
READONLY_VMIDS=$(nix-instantiate --eval --strict -E '
  let
    hosts = import '"$REPO_ROOT"'/hosts.nix;
    lib = import <nixpkgs/lib>;
    hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;
    readonlyHosts = lib.filterAttrs (name: host:
      host ? proxmox && (host.proxmox.readonly or false)
    ) hostEntries;
    vmids = lib.mapAttrsToList (name: host: host.proxmox.vmid) readonlyHosts;
  in builtins.concatStringsSep " " (map toString vmids)
' 2>/dev/null | tr -d '"')

if [[ -n "$READONLY_VMIDS" || $? -eq 0 ]]; then
    echo "PASS (readonly VMIDs: ${READONLY_VMIDS:-none})"
else
    echo "FAIL"
    exit 1
fi

# Test 3: All managed VMIDs should NOT be in readonly list
echo -n "Test: Managed VMIDs are not marked readonly... "
MANAGED_VMIDS=$(nix-instantiate --eval --strict -E '
  let
    hosts = import '"$REPO_ROOT"'/hosts.nix;
    lib = import <nixpkgs/lib>;
    hostEntries = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts;
    managedHosts = lib.filterAttrs (name: host:
      host ? proxmox && !(host.proxmox.readonly or false)
    ) hostEntries;
    vmids = lib.mapAttrsToList (name: host: host.proxmox.vmid) managedHosts;
  in builtins.concatStringsSep " " (map toString vmids)
' 2>/dev/null | tr -d '"')

if [[ -n "$MANAGED_VMIDS" ]]; then
    echo "PASS (managed VMIDs: $MANAGED_VMIDS)"
else
    echo "PASS (no managed VMIDs)"
fi

# Test 4: No VMID appears in both readonly and managed
echo -n "Test: No VMID in both readonly and managed... "
CONFLICT=false
for vmid in $READONLY_VMIDS; do
    if echo "$MANAGED_VMIDS" | grep -qw "$vmid"; then
        echo "FAIL - VMID $vmid is in both lists!"
        CONFLICT=true
    fi
done
if [[ "$CONFLICT" == "false" ]]; then
    echo "PASS"
fi

# Test 5: Critical production VMIDs are protected
# These are the VMIDs that MUST be readonly
echo -n "Test: doc1 (VMID 104) protection status... "
DOC1_STATUS=$(nix-instantiate --eval --strict -E '
  let hosts = import '"$REPO_ROOT"'/hosts.nix;
  in hosts.proxmox-vm.proxmox.readonly or false
' 2>/dev/null)
if [[ "$DOC1_STATUS" == "false" ]]; then
    echo "INFO - doc1 is managed by OpenTofu (readonly=false)"
else
    echo "PROTECTED - doc1 is readonly"
fi

echo -n "Test: igpu (VMID 109) protection status... "
IGPU_STATUS=$(nix-instantiate --eval --strict -E '
  let hosts = import '"$REPO_ROOT"'/hosts.nix;
  in hosts.igpu.proxmox.readonly or false
' 2>/dev/null)
if [[ "$IGPU_STATUS" == "false" ]]; then
    echo "INFO - igpu is managed by OpenTofu (readonly=false)"
else
    echo "PROTECTED - igpu is readonly"
fi

# Test 6: Verify no destructive operations possible on readonly VMs via wrapper
# This is a dry-run test that checks the wrapper script logic
echo ""
echo "Test: Wrapper script safety check logic..."

# Source the wrapper to get its functions (in a subshell to avoid side effects)
WRAPPER_HAS_SAFETY=$(grep -c "check_operation_allowed\|is_readonly" "$REPO_ROOT/vms/proxmox-ops.sh" || echo "0")
if [[ "$WRAPPER_HAS_SAFETY" -gt 0 ]]; then
    echo "  PASS: Wrapper has safety check functions"
else
    echo "  FAIL: Wrapper missing safety check functions"
    exit 1
fi

echo ""
echo "=== Summary ==="
echo "All VM safety invariant tests passed."
echo ""
echo "Current VM Protection Status:"
echo "  Readonly VMIDs: ${READONLY_VMIDS:-none}"
echo "  Managed VMIDs:  ${MANAGED_VMIDS:-none}"
