#!/usr/bin/env bash
# Update Snapshot Baselines
# =========================
# Creates/updates baseline files for derivation snapshot tests.
# Run this after intentional configuration changes.
# Usage: ./tests/update-baselines.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BASELINES_DIR="$SCRIPT_DIR/baselines"

mkdir -p "$BASELINES_DIR"

echo "========================================"
echo "    Updating Derivation Baselines"
echo "========================================"
echo ""

cd "$REPO_ROOT"

# Get all NixOS configuration names
echo "Fetching NixOS configurations..."
NIXOS_HOSTS=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

# Get all Home Manager configuration names
echo "Fetching Home Manager configurations..."
HOME_HOSTS=$(nix eval .#homeConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' ' ')

echo ""
echo "NixOS hosts: $NIXOS_HOSTS"
echo "Home Manager hosts: $HOME_HOSTS"
echo ""

# Update NixOS baselines
echo "Updating NixOS baselines..."
for host in $NIXOS_HOSTS; do
    echo -n "  $host... "
    toplevel=$(nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel" 2>/dev/null)
    echo "$toplevel" > "$BASELINES_DIR/nixos-${host}.txt"
    echo "done"
done

# Update Home Manager baselines
echo ""
echo "Updating Home Manager baselines..."
for host in $HOME_HOSTS; do
    echo -n "  $host... "
    activation=$(nix eval --raw ".#homeConfigurations.${host}.activationPackage" 2>/dev/null)
    echo "$activation" > "$BASELINES_DIR/home-${host}.txt"
    echo "done"
done

echo ""
echo "========================================"
echo "           Baselines Updated"
echo "========================================"
echo ""
echo "Updated files:"
ls -la "$BASELINES_DIR"/*.txt 2>/dev/null || echo "  (none)"
echo ""
echo "These baselines represent the current build outputs."
echo "Commit them to track intentional changes."
