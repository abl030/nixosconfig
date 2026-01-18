#!/usr/bin/env bash
# Inspect Changes
# ===============
# Shows what changed between baseline and current configuration.
# Usage:
#   ./tests/inspect-changes.sh                    # Show all changes
#   ./tests/inspect-changes.sh framework          # Show changes for specific host
#   ./tests/inspect-changes.sh framework --diff   # Show detailed derivation diff
#   ./tests/inspect-changes.sh framework --files  # Show changed generated files
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BASELINES_DIR="$SCRIPT_DIR/baselines"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$REPO_ROOT"

show_help() {
    cat << 'EOF'
Inspect Changes - Show what changed in NixOS configurations

Usage:
  ./tests/inspect-changes.sh [host] [options]

Arguments:
  host          Specific host to inspect (default: all hosts)

Options:
  --diff        Show detailed derivation diff using nvd
  --files       Show changes in generated config files
  --packages    Show package changes only
  --services    Show systemd service changes
  --summary     Just show which hosts changed (default if no options)
  --help        Show this help

Examples:
  ./tests/inspect-changes.sh                      # Summary of all changes
  ./tests/inspect-changes.sh framework            # Summary for framework
  ./tests/inspect-changes.sh framework --diff     # Detailed diff for framework
  ./tests/inspect-changes.sh framework --files    # Generated file changes
  ./tests/inspect-changes.sh --packages           # Package changes for all hosts

EOF
}

# Get baseline and current derivation for a host
get_derivations() {
    local host="$1"
    local type="${2:-nixos}"  # nixos or home

    local baseline_file="$BASELINES_DIR/${type}-${host}.txt"

    if [[ ! -f "$baseline_file" ]]; then
        echo "NO_BASELINE"
        return 1
    fi

    local baseline=$(cat "$baseline_file")
    local current

    if [[ "$type" == "nixos" ]]; then
        current=$(nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel" 2>/dev/null)
    else
        current=$(nix eval --raw ".#homeConfigurations.${host}.activationPackage" 2>/dev/null)
    fi

    echo "$baseline|$current"
}

# Show summary of changes
show_summary() {
    local host_filter="$1"

    echo "========================================"
    echo "         Configuration Changes"
    echo "========================================"
    echo ""

    # NixOS hosts
    echo "NixOS Configurations:"
    local nixos_hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

    for host in $nixos_hosts; do
        [[ -n "$host_filter" && "$host" != "$host_filter" ]] && continue

        local result=$(get_derivations "$host" "nixos")
        if [[ "$result" == "NO_BASELINE" ]]; then
            printf "  ${YELLOW}%-20s${NC} NO BASELINE\n" "$host"
        else
            local baseline="${result%%|*}"
            local current="${result##*|}"

            if [[ "$baseline" == "$current" ]]; then
                printf "  ${GREEN}%-20s${NC} unchanged\n" "$host"
            else
                printf "  ${RED}%-20s${NC} CHANGED\n" "$host"
                # Show hash difference
                local base_hash=$(basename "$baseline" | sed 's/nixos-system-[^-]*-//' | cut -c1-8)
                local curr_hash=$(basename "$current" | sed 's/nixos-system-[^-]*-//' | cut -c1-8)
                printf "    baseline: %s...\n" "$base_hash"
                printf "    current:  %s...\n" "$curr_hash"
            fi
        fi
    done

    echo ""
    echo "Home Manager Configurations:"
    local hm_hosts=$(nix eval .#homeConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

    for host in $hm_hosts; do
        [[ -n "$host_filter" && "$host" != "$host_filter" ]] && continue

        local result=$(get_derivations "$host" "home")
        if [[ "$result" == "NO_BASELINE" ]]; then
            printf "  ${YELLOW}%-20s${NC} NO BASELINE\n" "$host"
        else
            local baseline="${result%%|*}"
            local current="${result##*|}"

            if [[ "$baseline" == "$current" ]]; then
                printf "  ${GREEN}%-20s${NC} unchanged\n" "$host"
            else
                printf "  ${RED}%-20s${NC} CHANGED\n" "$host"
            fi
        fi
    done
}

# Show detailed diff using nvd
show_diff() {
    local host="$1"

    echo "========================================"
    echo "    Detailed Diff: $host"
    echo "========================================"
    echo ""

    local result=$(get_derivations "$host" "nixos")
    if [[ "$result" == "NO_BASELINE" ]]; then
        echo "No baseline found for $host"
        return 1
    fi

    local baseline="${result%%|*}"
    local current="${result##*|}"

    if [[ "$baseline" == "$current" ]]; then
        echo "No changes detected for $host"
        return 0
    fi

    echo "Baseline: $baseline"
    echo "Current:  $current"
    echo ""

    # Try nvd first (better output)
    if command -v nvd &>/dev/null || nix run nixpkgs#nvd -- --version &>/dev/null 2>&1; then
        echo "--- Package/Closure Changes (nvd) ---"
        nix run nixpkgs#nvd -- diff "$baseline" "$current" 2>/dev/null || echo "(nvd comparison failed)"
    else
        echo "Install nvd for detailed package diffs: nix run nixpkgs#nvd"
    fi
}

# Show package changes
show_packages() {
    local host="$1"

    echo "========================================"
    echo "    Package Changes: $host"
    echo "========================================"
    echo ""

    local result=$(get_derivations "$host" "nixos")
    if [[ "$result" == "NO_BASELINE" ]]; then
        echo "No baseline found for $host"
        return 1
    fi

    local baseline="${result%%|*}"
    local current="${result##*|}"

    if [[ "$baseline" == "$current" ]]; then
        echo "No changes detected for $host"
        return 0
    fi

    # Get system packages from both
    echo "Comparing installed packages..."
    echo ""

    local baseline_pkgs=$(nix path-info -r "$baseline" 2>/dev/null | xargs -I{} basename {} | sort -u)
    local current_pkgs=$(nix path-info -r "$current" 2>/dev/null | xargs -I{} basename {} | sort -u)

    echo "--- Removed packages ---"
    comm -23 <(echo "$baseline_pkgs") <(echo "$current_pkgs") | head -20

    echo ""
    echo "--- Added packages ---"
    comm -13 <(echo "$baseline_pkgs") <(echo "$current_pkgs") | head -20

    echo ""
    echo "(Showing first 20 of each. Use --diff for full comparison)"
}

# Show generated file changes
show_files() {
    local host="$1"

    echo "========================================"
    echo "    Generated Files: $host"
    echo "========================================"
    echo ""

    local result=$(get_derivations "$host" "nixos")
    if [[ "$result" == "NO_BASELINE" ]]; then
        echo "No baseline found for $host"
        return 1
    fi

    local baseline="${result%%|*}"
    local current="${result##*|}"

    # Key files to compare
    local files=(
        "etc/ssh/ssh_known_hosts"
        "etc/nix/nix.conf"
        "etc/nixos/configuration.nix"  # if exists
    )

    echo "Comparing key generated files..."
    echo ""

    for file in "${files[@]}"; do
        local base_file="$baseline/$file"
        local curr_file="$current/$file"

        if [[ -f "$base_file" || -f "$curr_file" ]]; then
            echo "--- $file ---"
            if [[ ! -f "$base_file" ]]; then
                echo "${GREEN}[NEW FILE]${NC}"
            elif [[ ! -f "$curr_file" ]]; then
                echo "${RED}[REMOVED]${NC}"
            elif ! diff -q "$base_file" "$curr_file" &>/dev/null; then
                echo "${YELLOW}[CHANGED]${NC}"
                diff --color=always -u "$base_file" "$curr_file" 2>/dev/null | head -30
            else
                echo "${GREEN}[unchanged]${NC}"
            fi
            echo ""
        fi
    done

    # Show systemd services that changed
    echo "--- Systemd Services ---"
    local base_services=$(ls "$baseline/etc/systemd/system/" 2>/dev/null | sort)
    local curr_services=$(ls "$current/etc/systemd/system/" 2>/dev/null | sort)

    local removed=$(comm -23 <(echo "$base_services") <(echo "$curr_services"))
    local added=$(comm -13 <(echo "$base_services") <(echo "$curr_services"))

    if [[ -n "$removed" ]]; then
        echo "Removed services:"
        echo "$removed" | sed 's/^/  - /' | head -10
    fi

    if [[ -n "$added" ]]; then
        echo "Added services:"
        echo "$added" | sed 's/^/  + /' | head -10
    fi

    if [[ -z "$removed" && -z "$added" ]]; then
        echo "No service changes detected"
    fi
}

# Show systemd service changes
show_services() {
    local host="$1"

    echo "========================================"
    echo "    Service Changes: $host"
    echo "========================================"
    echo ""

    local result=$(get_derivations "$host" "nixos")
    if [[ "$result" == "NO_BASELINE" ]]; then
        echo "No baseline found for $host"
        return 1
    fi

    local baseline="${result%%|*}"
    local current="${result##*|}"

    if [[ "$baseline" == "$current" ]]; then
        echo "No changes detected for $host"
        return 0
    fi

    echo "Systemd unit changes:"
    echo ""

    # Compare systemd directories
    for dir in "etc/systemd/system" "etc/systemd/user"; do
        if [[ -d "$baseline/$dir" || -d "$current/$dir" ]]; then
            echo "--- $dir ---"

            local base_units=$(ls "$baseline/$dir" 2>/dev/null | sort)
            local curr_units=$(ls "$current/$dir" 2>/dev/null | sort)

            # Removed
            local removed=$(comm -23 <(echo "$base_units") <(echo "$curr_units"))
            if [[ -n "$removed" ]]; then
                echo -e "${RED}Removed:${NC}"
                echo "$removed" | sed 's/^/  /'
            fi

            # Added
            local added=$(comm -13 <(echo "$base_units") <(echo "$curr_units"))
            if [[ -n "$added" ]]; then
                echo -e "${GREEN}Added:${NC}"
                echo "$added" | sed 's/^/  /'
            fi

            # Modified (same name, different content)
            local common=$(comm -12 <(echo "$base_units") <(echo "$curr_units"))
            local modified=""
            for unit in $common; do
                if ! diff -q "$baseline/$dir/$unit" "$current/$dir/$unit" &>/dev/null 2>&1; then
                    modified="$modified $unit"
                fi
            done
            if [[ -n "$modified" ]]; then
                echo -e "${YELLOW}Modified:${NC}"
                echo "$modified" | tr ' ' '\n' | grep -v '^$' | sed 's/^/  /'
            fi

            echo ""
        fi
    done
}

# Main
HOST_FILTER=""
ACTION="summary"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --diff)
            ACTION="diff"
            shift
            ;;
        --files)
            ACTION="files"
            shift
            ;;
        --packages)
            ACTION="packages"
            shift
            ;;
        --services)
            ACTION="services"
            shift
            ;;
        --summary)
            ACTION="summary"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            HOST_FILTER="$1"
            shift
            ;;
    esac
done

case "$ACTION" in
    summary)
        show_summary "$HOST_FILTER"
        ;;
    diff)
        if [[ -z "$HOST_FILTER" ]]; then
            echo "Please specify a host for --diff"
            echo "Usage: ./tests/inspect-changes.sh <host> --diff"
            exit 1
        fi
        show_diff "$HOST_FILTER"
        ;;
    files)
        if [[ -z "$HOST_FILTER" ]]; then
            echo "Please specify a host for --files"
            exit 1
        fi
        show_files "$HOST_FILTER"
        ;;
    packages)
        if [[ -z "$HOST_FILTER" ]]; then
            # Show for all changed hosts
            nixos_hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')
            for host in $nixos_hosts; do
                result=$(get_derivations "$host" "nixos")
                if [[ "$result" != "NO_BASELINE" ]]; then
                    baseline="${result%%|*}"
                    current="${result##*|}"
                    if [[ "$baseline" != "$current" ]]; then
                        show_packages "$host"
                        echo ""
                    fi
                fi
            done
        else
            show_packages "$HOST_FILTER"
        fi
        ;;
    services)
        if [[ -z "$HOST_FILTER" ]]; then
            echo "Please specify a host for --services"
            exit 1
        fi
        show_services "$HOST_FILTER"
        ;;
esac
