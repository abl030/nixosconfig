#!/usr/bin/env bash
# Inspect Configuration Values
# ============================
# Query and compare specific configuration values across hosts.
# Usage:
#   ./tests/inspect-config.sh framework networking.hostName
#   ./tests/inspect-config.sh --all homelab.ssh.enable
#   ./tests/inspect-config.sh --compare services.openssh.enable
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

show_help() {
    cat << 'EOF'
Inspect Configuration Values

Usage:
  ./tests/inspect-config.sh <host> <option-path>     # Get single value
  ./tests/inspect-config.sh --all <option-path>      # Get value from all hosts
  ./tests/inspect-config.sh --compare <option-path>  # Compare across hosts

Common option paths:
  networking.hostName
  users.users.<name>.home
  services.openssh.enable
  services.tailscale.enable
  homelab.ssh.enable
  homelab.ssh.secure
  homelab.tailscale.enable
  homelab.nixCaches.profile
  programs.ssh.knownHosts
  nix.settings.experimental-features
  environment.systemPackages

Examples:
  ./tests/inspect-config.sh framework networking.hostName
  ./tests/inspect-config.sh --all homelab.ssh.secure
  ./tests/inspect-config.sh --compare homelab.nixCaches.profile
  ./tests/inspect-config.sh framework 'builtins.length config.environment.systemPackages'

EOF
}

# Get a config value for a host
get_config_value() {
    local host="$1"
    local path="$2"

    # Handle special cases where we need full expression
    if [[ "$path" == *"builtins"* || "$path" == *"lib."* ]]; then
        nix eval --impure --expr "
          let
            flake = builtins.getFlake \"path:${REPO_ROOT}\";
            config = flake.nixosConfigurations.${host}.config;
            pkgs = flake.nixosConfigurations.${host}.pkgs;
            lib = pkgs.lib;
          in ${path}
        " 2>/dev/null
    else
        nix eval ".#nixosConfigurations.${host}.config.${path}" 2>/dev/null
    fi
}

# Get value for single host
show_single() {
    local host="$1"
    local path="$2"

    echo "Host: $host"
    echo "Path: $path"
    echo "Value:"
    get_config_value "$host" "$path"
}

# Get value for all hosts
show_all() {
    local path="$1"

    echo "Configuration value across all hosts"
    echo "Path: $path"
    echo "========================================"
    echo ""

    local hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

    for host in $hosts; do
        printf "%-20s " "$host:"
        get_config_value "$host" "$path" || echo "(not set)"
    done
}

# Compare values across hosts, highlighting differences
compare_all() {
    local path="$1"

    echo "Comparing: $path"
    echo "========================================"
    echo ""

    local hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

    declare -A values
    local first_value=""

    for host in $hosts; do
        local value=$(get_config_value "$host" "$path" 2>/dev/null || echo "NOT_SET")
        values[$host]="$value"
        if [[ -z "$first_value" ]]; then
            first_value="$value"
        fi
    done

    # Group hosts by value
    declare -A by_value
    for host in "${!values[@]}"; do
        local v="${values[$host]}"
        by_value[$v]="${by_value[$v]:-} $host"
    done

    if [[ ${#by_value[@]} -eq 1 ]]; then
        echo -e "\033[0;32mAll hosts have the same value:\033[0m"
        echo "  $first_value"
        echo ""
        echo "Hosts: $hosts"
    else
        echo -e "\033[1;33mValues differ across hosts:\033[0m"
        echo ""
        for value in "${!by_value[@]}"; do
            echo "Value: $value"
            echo "  Hosts:${by_value[$value]}"
            echo ""
        done
    fi
}

# Inspect known hosts specifically
inspect_known_hosts() {
    local host="$1"

    echo "SSH Known Hosts for: $host"
    echo "========================================"
    echo ""

    nix eval --json ".#nixosConfigurations.${host}.config.programs.ssh.knownHosts" 2>/dev/null | \
        nix run nixpkgs#jq -- -r 'to_entries[] | "\(.key): \(.value.hostNames | join(", "))"' 2>/dev/null || \
        echo "(Could not parse known hosts)"
}

# Inspect systemPackages
inspect_packages() {
    local host="$1"

    echo "System Packages for: $host"
    echo "========================================"
    echo ""

    nix eval --impure --expr "
      let
        flake = builtins.getFlake \"path:${REPO_ROOT}\";
        pkgs = flake.nixosConfigurations.${host}.config.environment.systemPackages;
      in builtins.map (p: p.name or p.pname or \"unknown\") pkgs
    " 2>/dev/null | tr ',' '\n' | tr -d '[]"' | sort
}

# Main
if [[ $# -lt 1 ]]; then
    show_help
    exit 1
fi

case "$1" in
    --help|-h)
        show_help
        exit 0
        ;;
    --all)
        if [[ $# -lt 2 ]]; then
            echo "Usage: ./tests/inspect-config.sh --all <option-path>"
            exit 1
        fi
        show_all "$2"
        ;;
    --compare)
        if [[ $# -lt 2 ]]; then
            echo "Usage: ./tests/inspect-config.sh --compare <option-path>"
            exit 1
        fi
        compare_all "$2"
        ;;
    --known-hosts)
        if [[ $# -lt 2 ]]; then
            echo "Usage: ./tests/inspect-config.sh --known-hosts <host>"
            exit 1
        fi
        inspect_known_hosts "$2"
        ;;
    --packages)
        if [[ $# -lt 2 ]]; then
            echo "Usage: ./tests/inspect-config.sh --packages <host>"
            exit 1
        fi
        inspect_packages "$2"
        ;;
    *)
        if [[ $# -lt 2 ]]; then
            echo "Usage: ./tests/inspect-config.sh <host> <option-path>"
            echo "       ./tests/inspect-config.sh --help"
            exit 1
        fi
        show_single "$1" "$2"
        ;;
esac
