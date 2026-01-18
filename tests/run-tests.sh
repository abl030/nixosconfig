#!/usr/bin/env bash
# Test Runner
# ===========
# Runs all tests and reports results.
# Usage: ./tests/run-tests.sh [--verbose]
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VERBOSE="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

passed=0
failed=0
skipped=0

print_result() {
    local name="$1"
    local status="$2"
    local message="${3:-}"

    case "$status" in
        pass)
            printf "${GREEN}PASS${NC}: %s\n" "$name"
            ((passed++)) || true
            ;;
        fail)
            printf "${RED}FAIL${NC}: %s\n" "$name"
            [[ -n "$message" ]] && printf "      %s\n" "$message"
            ((failed++)) || true
            ;;
        skip)
            printf "${YELLOW}SKIP${NC}: %s\n" "$name"
            [[ -n "$message" ]] && printf "      %s\n" "$message"
            ((skipped++)) || true
            ;;
    esac
}

run_nix_eval() {
    local expr="$1"
    timeout 120 nix-instantiate --eval --strict -E "$expr" 2>&1
}

run_flake_test() {
    local test_name="$1"
    local test_args="$2"

    timeout 120 nix eval --impure --expr "
      let
        flake = builtins.getFlake \"path:${REPO_ROOT}\";
        pkgs = import <nixpkgs> {};
        test = import ${REPO_ROOT}/tests/${test_name}.nix { ${test_args} };
      in test.check
    " 2>&1
}

echo "========================================"
echo "       NixOS Config Test Suite"
echo "========================================"
echo ""

cd "$REPO_ROOT"

# ============================================
# STANDALONE TESTS (no flake context needed)
# ============================================
echo "--- Standalone Tests ---"

# Test 1: hosts.nix Schema Validation
printf "Testing: hosts-schema... "
result=$(run_nix_eval 'let t = import ./tests/hosts-schema.nix {}; in t.check')
if [[ "$result" == "true" ]]; then
    print_result "hosts-schema" "pass"
else
    print_result "hosts-schema" "fail" "$result"
fi

# Test 2: OpenTofu Consistency
printf "Testing: tofu-consistency... "
result=$(run_nix_eval 'let t = import ./tests/tofu-consistency.nix { hosts = import ./hosts.nix; lib = import <nixpkgs/lib>; }; in t.check')
if [[ "$result" == "true" ]]; then
    print_result "tofu-consistency" "pass"
else
    print_result "tofu-consistency" "fail" "$result"
fi

# Test 3: VM Safety (shell script)
printf "Testing: vm-safety... "
if "$SCRIPT_DIR/vm-safety.sh" >/dev/null 2>&1; then
    print_result "vm-safety" "pass"
else
    print_result "vm-safety" "fail" "Script returned non-zero"
fi

echo ""
echo "--- Flake-Dependent Tests ---"

# Test 4: special-args
printf "Testing: special-args... "
result=$(run_flake_test "special-args" "inherit (flake) nixosConfigurations homeConfigurations; hosts = import ${REPO_ROOT}/hosts.nix;")
if [[ "$result" == "true" ]]; then
    print_result "special-args" "pass"
else
    print_result "special-args" "fail" "${result:0:100}"
fi

# Test 5: base-profile
printf "Testing: base-profile... "
result=$(run_flake_test "base-profile" "inherit (flake) nixosConfigurations; hosts = import ${REPO_ROOT}/hosts.nix; lib = pkgs.lib;")
if [[ "$result" == "true" ]]; then
    print_result "base-profile" "pass"
else
    print_result "base-profile" "fail" "${result:0:100}"
fi

# Test 6: ssh-trust
printf "Testing: ssh-trust... "
result=$(run_flake_test "ssh-trust" "inherit (flake) nixosConfigurations; hosts = import ${REPO_ROOT}/hosts.nix; lib = pkgs.lib;")
if [[ "$result" == "true" ]]; then
    print_result "ssh-trust" "pass"
else
    print_result "ssh-trust" "fail" "${result:0:100}"
fi

# Test 7: module-options
printf "Testing: module-options... "
result=$(run_flake_test "module-options" "inherit (flake) nixosConfigurations; lib = pkgs.lib;")
if [[ "$result" == "true" ]]; then
    print_result "module-options" "pass"
else
    print_result "module-options" "fail" "${result:0:100}"
fi

# Test 8: sops-paths
printf "Testing: sops-paths... "
result=$(run_flake_test "sops-paths" "inherit (flake) nixosConfigurations; lib = pkgs.lib; flakeRoot = ${REPO_ROOT};")
if [[ "$result" == "true" ]]; then
    print_result "sops-paths" "pass"
else
    print_result "sops-paths" "fail" "${result:0:100}"
fi

# Test 9: Snapshots
printf "Testing: snapshots... "
snapshot_changed=0
snapshot_missing=0
snapshot_match=0
BASELINES_DIR="$REPO_ROOT/tests/baselines"

# Get list of NixOS hosts
nixos_hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')
for host in $nixos_hosts; do
    baseline_file="$BASELINES_DIR/nixos-${host}.txt"
    if [[ -f "$baseline_file" ]]; then
        baseline=$(cat "$baseline_file")
        current=$(nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel" 2>/dev/null || echo "ERROR")
        if [[ "$baseline" == "$current" ]]; then
            ((snapshot_match++)) || true
        else
            ((snapshot_changed++)) || true
        fi
    else
        ((snapshot_missing++)) || true
    fi
done

# Get list of HM hosts
hm_hosts=$(nix eval .#homeConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')
for host in $hm_hosts; do
    baseline_file="$BASELINES_DIR/home-${host}.txt"
    if [[ -f "$baseline_file" ]]; then
        baseline=$(cat "$baseline_file")
        current=$(nix eval --raw ".#homeConfigurations.${host}.activationPackage" 2>/dev/null || echo "ERROR")
        if [[ "$baseline" == "$current" ]]; then
            ((snapshot_match++)) || true
        else
            ((snapshot_changed++)) || true
        fi
    else
        ((snapshot_missing++)) || true
    fi
done

if [[ $snapshot_changed -gt 0 ]]; then
    print_result "snapshots" "fail" "$snapshot_changed changed"
elif [[ $snapshot_missing -gt 0 ]]; then
    print_result "snapshots" "skip" "$snapshot_missing missing baselines"
else
    print_result "snapshots" "pass"
fi

echo ""
echo "========================================"
echo "                Summary"
echo "========================================"
printf "  ${GREEN}Passed${NC}:  %d\n" "$passed"
printf "  ${RED}Failed${NC}:  %d\n" "$failed"
printf "  ${YELLOW}Skipped${NC}: %d\n" "$skipped"
echo ""

if [[ $failed -gt 0 ]]; then
    printf "${RED}Some tests failed!${NC}\n"
    exit 1
elif [[ $skipped -gt 0 ]]; then
    printf "${YELLOW}Some tests were skipped.${NC}\n"
    exit 0
else
    printf "${GREEN}All tests passed!${NC}\n"
    exit 0
fi
