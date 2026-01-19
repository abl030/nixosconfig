#!/usr/bin/env bash
# hash-capture.sh - Capture derivation hashes for all NixOS and Home Manager configurations
#
# NixOS's deterministic builds mean identical toplevel hashes guarantee identical systems.
# This script captures current hashes as a baseline for detecting configuration drift.
#
# Usage:
#   ./scripts/hash-capture.sh              # Capture all hashes
#   ./scripts/hash-capture.sh --quiet      # Suppress progress output
#   ./scripts/hash-capture.sh --nixos-only # Capture only NixOS hashes
#   ./scripts/hash-capture.sh --home-only  # Capture only Home Manager hashes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HASHES_DIR="$REPO_ROOT/hashes"

QUIET=false
CAPTURE_NIXOS=true
CAPTURE_HOME=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=true; shift ;;
        --nixos-only) CAPTURE_HOME=false; shift ;;
        --home-only) CAPTURE_NIXOS=false; shift ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

log() {
    $QUIET || echo "$1"
}

mkdir -p "$HASHES_DIR"

cd "$REPO_ROOT"

if $CAPTURE_NIXOS; then
    log "Capturing NixOS configuration hashes..."
    nixos_hosts=$(nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' '\n')

    for host in $nixos_hosts; do
        [[ -z "$host" ]] && continue
        log "  nixos-$host"
        hash=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel" 2>/dev/null) || {
            echo "  WARNING: Failed to evaluate nixos-$host" >&2
            continue
        }
        echo "$hash" > "$HASHES_DIR/nixos-$host.txt"
    done
fi

if $CAPTURE_HOME; then
    log "Capturing Home Manager configuration hashes..."
    home_hosts=$(nix eval .#homeConfigurations --apply 'x: builtins.attrNames x' --json 2>/dev/null | tr -d '[]"' | tr ',' '\n')

    for host in $home_hosts; do
        [[ -z "$host" ]] && continue
        log "  home-$host"
        hash=$(nix eval --raw ".#homeConfigurations.$host.activationPackage" 2>/dev/null) || {
            echo "  WARNING: Failed to evaluate home-$host" >&2
            continue
        }
        echo "$hash" > "$HASHES_DIR/home-$host.txt"
    done
fi

log ""
log "Hashes captured to $HASHES_DIR/"
log "$(ls -1 "$HASHES_DIR"/*.txt 2>/dev/null | wc -l) configurations captured."
