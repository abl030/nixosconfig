#!/usr/bin/env bash
# doc1-migration-permissions.sh
# One-time script to fix /mnt/docker permissions for rootless podman migration
#
# Run this ONCE on doc1 before enabling stacks:
#   sudo ./scripts/doc1-migration-permissions.sh
#
# This replaces the per-stack chown -R commands that would otherwise run on every start.

set -euo pipefail

DATA_ROOT="/mnt/docker"
TARGET_UID=1000
TARGET_GID=1000

echo "=== Doc1 Rootless Podman Migration - Permission Fix ==="
echo "DATA_ROOT: $DATA_ROOT"
echo "Target ownership: $TARGET_UID:$TARGET_GID"
echo ""

# Ensure we're running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

fix_permissions() {
    local dir="$1"
    local desc="$2"

    if [[ -d "$dir" ]]; then
        echo "  Fixing: $dir ($desc)"
        chown -R "$TARGET_UID:$TARGET_GID" "$dir"
    else
        echo "  Creating: $dir ($desc)"
        mkdir -p "$dir"
        chown -R "$TARGET_UID:$TARGET_GID" "$dir"
    fi
}

echo "--- management ---"
fix_permissions "$DATA_ROOT/dozzle/data" "dozzle data"
fix_permissions "$DATA_ROOT/gotify/data" "gotify data"

echo "--- tailscale-caddy ---"
fix_permissions "$DATA_ROOT/tailscale/ts-state" "tailscale state"
fix_permissions "$DATA_ROOT/tailscale/caddy_data" "caddy data"
fix_permissions "$DATA_ROOT/tailscale/caddy_config" "caddy config"

echo "--- immich ---"
fix_permissions "$DATA_ROOT/tailscale/immich" "immich tailscale"
fix_permissions "$DATA_ROOT/AI/immich" "immich AI models"
fix_permissions "$DATA_ROOT/immichPG" "immich postgres"

echo "--- paperless ---"
fix_permissions "$DATA_ROOT/paperless" "paperless (all)"
fix_permissions "$DATA_ROOT/paperlessgpt" "paperlessgpt"

echo "--- mealie ---"
fix_permissions "$DATA_ROOT/mealie" "mealie (all)"

echo "--- kopia ---"
fix_permissions "$DATA_ROOT/kopiaphotos" "kopia photos"
fix_permissions "$DATA_ROOT/kopiamum" "kopia mum"

echo "--- atuin ---"
fix_permissions "$DATA_ROOT/atuin" "atuin (all)"

echo "--- audiobookshelf ---"
fix_permissions "$DATA_ROOT/audiobookshelf" "audiobookshelf (all)"

echo "--- domain-monitor ---"
fix_permissions "$DATA_ROOT/domain-monitor" "domain-monitor (all)"

echo "--- invoices ---"
fix_permissions "$DATA_ROOT/invoices" "invoices (all)"

echo "--- jdownloader2 ---"
fix_permissions "$DATA_ROOT/jdownloader2" "jdownloader2 (all)"

echo "--- music ---"
fix_permissions "$DATA_ROOT/ombi" "ombi (all)"
fix_permissions "$DATA_ROOT/music" "music (all)"
fix_permissions "$DATA_ROOT/tailscale/music" "music tailscale"

echo "--- netboot ---"
fix_permissions "$DATA_ROOT/netboot" "netboot (all)"

echo "--- smokeping ---"
fix_permissions "$DATA_ROOT/smokeping" "smokeping (all)"

echo "--- stirlingpdf ---"
fix_permissions "$DATA_ROOT/StirlingPDF" "stirlingpdf (all)"

echo "--- tautulli ---"
fix_permissions "$DATA_ROOT/tautulli" "tautulli (all)"

echo "--- uptime-kuma ---"
fix_permissions "$DATA_ROOT/uptime-kuma" "uptime-kuma (all)"

echo "--- youtarr ---"
fix_permissions "$DATA_ROOT/youtarr" "youtarr (all)"

echo ""
echo "=== Permission fix complete ==="
echo ""
echo "Next steps:"
echo "1. Enable stacks in hosts.nix containerStacks"
echo "2. Rebuild: nixos-rebuild switch --flake .#proxmox-vm"
echo "3. Verify stacks start without permission errors"
echo ""
echo "NOTE: Database containers use :U volume flag for uid namespace mapping."
echo "      This script sets base ownership; podman handles the rest."
