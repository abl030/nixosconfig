#!/usr/bin/env bash
# hash-compare.sh - Compare current derivation hashes against stored baselines
#
# NixOS's deterministic builds mean identical toplevel hashes guarantee identical systems.
# If hashes differ, uses nix-diff to show exactly what changed.
#
# Usage:
#   ./scripts/hash-compare.sh                   # Compare all hosts
#   ./scripts/hash-compare.sh --summary         # Only show summary, skip nix-diff details
#   ./scripts/hash-compare.sh --nixos-only      # Only check NixOS baselines
#   ./scripts/hash-compare.sh --home-only       # Only check Home Manager baselines
#   ./scripts/hash-compare.sh <host>            # Compare specific host (e.g., "framework" or "nixos-framework")
#
# Exit codes:
#   0 - All hashes match (pure refactor)
#   1 - Some hashes differ (config drift detected)
#   2 - Missing baselines (run hash-capture.sh first)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HASHES_DIR="$REPO_ROOT/hashes"

SUMMARY_ONLY=false
CHECK_NIXOS=true
CHECK_HOME=true
SPECIFIC_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) SUMMARY_ONLY=true; shift ;;
        --nixos-only) CHECK_HOME=false; shift ;;
        --home-only) CHECK_NIXOS=false; shift ;;
        *) SPECIFIC_HOST="$1"; shift ;;
    esac
done

cd "$REPO_ROOT"

# Check if hashes directory exists
if [[ ! -d "$HASHES_DIR" ]] || [[ -z "$(ls -A "$HASHES_DIR" 2>/dev/null)" ]]; then
    echo "No baseline hashes found in $HASHES_DIR/"
    echo "Run ./scripts/hash-capture.sh first to create baselines."
    exit 2
fi

# Arrays to track results
declare -a matched=()
declare -a changed=()
declare -a missing=()
declare -a errors=()

# Store detailed diffs for later output
declare -A diffs=()

echo "=== Hash-Based Configuration Drift Detection ==="
echo ""

compare_config() {
    local type="$1"  # "nixos" or "home"
    local host="$2"
    local baseline_file="$HASHES_DIR/${type}-${host}.txt"
    local label="${type}-${host}"

    # Check if baseline exists
    if [[ ! -f "$baseline_file" ]]; then
        missing+=("$label")
        return
    fi

    local baseline
    baseline=$(cat "$baseline_file")

    # Get current hash
    local current
    if [[ "$type" == "nixos" ]]; then
        current=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel" 2>/dev/null) || {
            errors+=("$label: evaluation failed")
            return
        }
    else
        current=$(nix eval --raw ".#homeConfigurations.$host.activationPackage" 2>/dev/null) || {
            errors+=("$label: evaluation failed")
            return
        }
    fi

    # Compare
    if [[ "$baseline" == "$current" ]]; then
        matched+=("$label")
        echo "  MATCH: $label"
    else
        changed+=("$label")
        echo "  DRIFT: $label"

        # Capture nix-diff output if not summary only
        if ! $SUMMARY_ONLY; then
            local diff_output
            # Get derivation paths for nix-diff
            local baseline_drv current_drv
            if [[ "$type" == "nixos" ]]; then
                baseline_drv=$(nix path-info --derivation "$baseline" 2>/dev/null) || baseline_drv="$baseline"
                current_drv=$(nix path-info --derivation "$current" 2>/dev/null) || current_drv="$current"
            else
                baseline_drv=$(nix path-info --derivation "$baseline" 2>/dev/null) || baseline_drv="$baseline"
                current_drv=$(nix path-info --derivation "$current" 2>/dev/null) || current_drv="$current"
            fi

            diff_output=$(nix run nixpkgs#nix-diff -- "$baseline_drv" "$current_drv" 2>&1) || true
            diffs["$label"]="$diff_output"
        fi
    fi
}

if $CHECK_NIXOS; then
    echo "Comparing NixOS configurations..."
    nixos_hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' '\n')

    for host in $nixos_hosts; do
        [[ -z "$host" ]] && continue
        # Filter if specific host requested
        if [[ -n "$SPECIFIC_HOST" ]]; then
            [[ "$host" != "$SPECIFIC_HOST" && "nixos-$host" != "$SPECIFIC_HOST" ]] && continue
        fi
        compare_config "nixos" "$host"
    done
fi

if $CHECK_HOME; then
    echo ""
    echo "Comparing Home Manager configurations..."
    home_hosts=$(nix eval .#homeConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' '\n')

    for host in $home_hosts; do
        [[ -z "$host" ]] && continue
        # Filter if specific host requested
        if [[ -n "$SPECIFIC_HOST" ]]; then
            [[ "$host" != "$SPECIFIC_HOST" && "home-$host" != "$SPECIFIC_HOST" ]] && continue
        fi
        compare_config "home" "$host"
    done
fi

# Print detailed diffs if any
if ! $SUMMARY_ONLY && [[ ${#changed[@]} -gt 0 ]]; then
    echo ""
    echo "=== Detailed Drift Analysis (nix-diff) ==="
    for label in "${changed[@]}"; do
        echo ""
        echo "--- $label ---"
        if [[ -n "${diffs[$label]:-}" ]]; then
            echo "${diffs[$label]}"
        else
            echo "(no diff available)"
        fi
    done
fi

# Print summary
echo ""
echo "=== Summary ==="
echo "  Matched: ${#matched[@]}"
echo "  Drifted: ${#changed[@]}"
[[ ${#missing[@]} -gt 0 ]] && echo "  Missing baselines: ${#missing[@]} (${missing[*]})"
[[ ${#errors[@]} -gt 0 ]] && echo "  Errors: ${#errors[@]} (${errors[*]})"

if [[ ${#changed[@]} -eq 0 && ${#missing[@]} -eq 0 && ${#errors[@]} -eq 0 ]]; then
    echo ""
    echo "All configurations match baselines. Pure refactor verified."
    exit 0
else
    echo ""
    if [[ ${#changed[@]} -gt 0 ]]; then
        echo "Configuration drift detected in: ${changed[*]}"
    fi
    exit 1
fi
