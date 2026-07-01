#!/usr/bin/env bash
# push_deploy.sh — activate pre-built closures on push-deploy fleet hosts.
#
# Runs on the doc1 bastion at the end of rolling_flake_update.sh. For each
# configured push-deploy host it:
#   1. Resolves the GC-root symlink populate_cache.sh left for that host
#      (${CI_RESULTS_DIR}/<host>-system -> /nix/store/…-nixos-system-<host>-…).
#   2. SSHes to `root@<host>` using doc1's fleet-deploy trigger key, passing the
#      store path as the command. The host's root authorized_keys entry is a
#      forced command (modules/nixos/autoupdate/push-deploy.nix): sshd ignores the
#      requested command, runs the activation wrapper, and hands it the path via
#      $SSH_ORIGINAL_COMMAND. The wrapper (as root) realises the closure from
#      nixcache.ablz.au (signature-checked) and runs switch-to-configuration.
#
# No sudo, no polkit, no login-user involvement on the target — the key can do
# exactly one thing (activate a doc1-signed closure) and only doc1 holds it.
#
# Env vars (set by modules/nixos/ci/rolling-flake-update.nix):
#   RFU_PUSH_DEPLOY_HOST_MAP  comma-separated "name:addr" pairs (addr = ssh host)
#   RFU_CI_RESULTS_DIR        dir of populate_cache.sh GC-root symlinks
#   RFU_DEPLOY_KEY            path to doc1's deploy-trigger private key
#
# Forgejo issue #10.
set -euo pipefail

TAG="push-deploy"
HOST_MAP="${RFU_PUSH_DEPLOY_HOST_MAP:-}"
CI_RESULTS_DIR="${RFU_CI_RESULTS_DIR:-/home/abl030/.cache/nix-ci-results}"
DEPLOY_KEY="${RFU_DEPLOY_KEY:-}"

log() { echo "[$TAG] $*"; }

if [ -z "$HOST_MAP" ]; then
    log "no push-deploy hosts configured (RFU_PUSH_DEPLOY_HOST_MAP empty); skipping"
    exit 0
fi
if [ -z "$DEPLOY_KEY" ] || [ ! -r "$DEPLOY_KEY" ]; then
    log "deploy key unreadable (RFU_DEPLOY_KEY='$DEPLOY_KEY'); cannot trigger activation" >&2
    exit 1
fi

any_fail=0

push_deploy_host() {
    local entry="$1"
    # Entry format: "name:addr"
    local name="${entry%%:*}"
    local addr="${entry#*:}"

    log "[$name] starting push-deploy to root@$addr"

    local gc_root="$CI_RESULTS_DIR/${name}-system"
    if [ ! -L "$gc_root" ]; then
        log "[$name] no GC root at $gc_root — build may have failed; skipping"
        return 1
    fi

    local toplevel
    toplevel="$(readlink -f "$gc_root")"
    if [ -z "$toplevel" ] || [ ! -d "$toplevel" ]; then
        log "[$name] GC root at $gc_root resolves to nothing; skipping"
        return 1
    fi

    log "[$name] activating $toplevel"

    # Pass the store path as the SSH command; the host's forced command turns it
    # into $SSH_ORIGINAL_COMMAND for the activation wrapper. Blocking (no
    # --no-block equivalent) so we get a clean success/failure signal here.
    if ! ssh \
            -i "$DEPLOY_KEY" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new \
            "root@$addr" \
            "$toplevel"; then
        log "[$name] push-deploy FAILED (ssh/realise/activate)"
        return 1
    fi

    log "[$name] push-deploy done"
}

# Parse HOST_MAP: comma-separated "name:addr"
IFS=',' read -ra ENTRIES <<< "$HOST_MAP"
for entry in "${ENTRIES[@]}"; do
    [ -n "$entry" ] || continue
    push_deploy_host "$entry" || { any_fail=1; true; }
done

exit "$any_fail"
