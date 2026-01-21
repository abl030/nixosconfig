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
log_file="$(mktemp)"
if nix build .#homeConfigurations.framework.activationPackage >"$log_file" 2>&1; then
  log "Build succeeded. No cargo hash update needed."
  rm -f "$log_file"
  exit 0
fi

hash="$(rg -o "got: sha256-[A-Za-z0-9+/=]+" "$log_file" | head -n1 | sed "s/got: //")"

if [[ -z "$hash" ]]; then
  log "Build failed and no cargo hash was found. Log excerpt:"
  tail -n 50 "$log_file" >&2
  rm -f "$log_file"
  exit 1
fi

log "Updating cargoHash in nix/overlay.nix to $hash"
perl -pi -e "s/cargoHash = \"sha256-[A-Za-z0-9+\/=]+\";/cargoHash = \"$hash\";/" nix/overlay.nix

log "Rebuilding to verify updated cargo hash..."
nix build .#homeConfigurations.framework.activationPackage
rm -f "$log_file"
log "Done."
