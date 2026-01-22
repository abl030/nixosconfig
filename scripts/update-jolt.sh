#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

log() {
  echo "[jolt-update] $*"
}

log "Updating flake input jolt-src..."
nix flake update jolt-src

log "Building framework Home Manager activation to verify jolt..."
nix build .#homeConfigurations.framework.activationPackage
log "Done."
