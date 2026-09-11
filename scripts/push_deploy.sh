#!/usr/bin/env bash
# push_deploy.sh — activate pre-built closures on push-deploy fleet hosts.
#
# Runs on the doc1 bastion at the end of rolling_flake_update.sh. For each
# configured push-deploy host it:
#   1. Resolves the GC-root symlink populate_cache.sh left for that host
#      (${CI_RESULTS_DIR}/<host>-system -> /nix/store/…-nixos-system-<host>-…).
#   2. TRIGGERS activation: SSH to `root@<host>` with doc1's fleet-deploy trigger
#      key, passing the store path as the command. The host's root authorized_keys
#      entry is a forced command (modules/nixos/autoupdate/push-deploy.nix): sshd
#      runs the trigger wrapper, which stages the path and fires
#      push-activate.service --no-block, then the root session exits immediately.
#      The heavy realise + switch-to-configuration runs under PID 1, NOT in the SSH
#      session (so root's runtime dir tears down cleanly — see the module header).
#   3. POLLS the host (read-only, no privilege) until push-activate.service
#      finishes: success when the system generation == the target closure and the
#      service isn't failed; failure on a failed unit or timeout.
#
# No sudo, no polkit, no login-user involvement in the activation — the key can do
# exactly one thing (trigger a doc1-signed closure) and only doc1 holds it.
#
# Env vars (set by modules/nixos/ci/rolling-flake-update.nix):
#   RFU_PUSH_DEPLOY_HOST_MAP  comma-separated "name:addr" pairs (addr = ssh host)
#   RFU_PUSH_DEPLOY_OPTIONAL  comma-separated host names that are EXPECTED to be
#                             powered off; unreachable => skip, not fail
#   RFU_CI_RESULTS_DIR        dir of populate_cache.sh GC-root symlinks
#   RFU_DEPLOY_KEY            path to doc1's deploy-trigger private key
#
# Forgejo issue #10.
set -euo pipefail

TAG="push-deploy"
HOST_MAP="${RFU_PUSH_DEPLOY_HOST_MAP:-}"
CI_RESULTS_DIR="${RFU_CI_RESULTS_DIR:-/home/abl030/.cache/nix-ci-results}"
DEPLOY_KEY="${RFU_DEPLOY_KEY:-}"
OPTIONAL_HOSTS="${RFU_PUSH_DEPLOY_OPTIONAL:-}"

# Poll budget: 3s between reads, up to 100 reads (~5 min) — a cold cache pull plus
# switch fits comfortably; a real failure surfaces well before the ceiling.
POLL_INTERVAL="${RFU_PUSH_DEPLOY_POLL_INTERVAL:-3}"
POLL_MAX="${RFU_PUSH_DEPLOY_POLL_MAX:-100}"

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

# Read-only poll of the target via a normal (login-user) session — is-active +
# current generation in one round trip. No privilege needed.
poll_state() {
    local addr="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$addr" \
        'printf "%s %s\n" "$(systemctl is-active push-activate.service 2>/dev/null || true)" "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null)"' \
        2>/dev/null || echo "sshfail "
}

# Is this host allowed to be absent? (RFU_PUSH_DEPLOY_OPTIONAL)
is_optional() {
    case ",${OPTIONAL_HOSTS}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Cheap liveness probe: can we open a TCP connection to sshd at all?
# Deliberately NOT an ssh handshake — we only need to tell "powered off" apart
# from "up but broken". A trigger failure on a host that IS up must still count
# as a real failure.
host_reachable() {
    # shellcheck disable=SC2016  # $1 is the INNER bash's positional arg, passed
    # after the `_` placeholder; expanding it here would defeat the quoting.
    timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/22"' _ "$1" 2>/dev/null
}

push_deploy_host() {
    local entry="$1"
    # Entry format: "name:addr"
    local name="${entry%%:*}"
    local addr="${entry#*:}"

    # A host marked optional is expected to be powered off (e.g. imagegen-gpu,
    # whose GPU has one owner at a time). Skipping keeps the nightly run green
    # instead of paging for a machine that is off on purpose. If it IS up we
    # deploy it normally and any later failure still fails.
    if is_optional "$name" && ! host_reachable "$addr"; then
        log "[$name] unreachable and marked optional — skipping (expected to be powered off)"
        return 0
    fi

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

    log "[$name] triggering activation of $toplevel"
    # Pass the store path as the SSH command; the host's forced command turns it
    # into $SSH_ORIGINAL_COMMAND, stages it, and fires push-activate.service.
    if ! ssh \
            -i "$DEPLOY_KEY" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new \
            "root@$addr" \
            "$toplevel"; then
        log "[$name] FAILED to trigger (ssh/forced-command)"
        return 1
    fi

    # Poll until push-activate.service settles.
    local i state gen
    for ((i = 1; i <= POLL_MAX; i++)); do
        sleep "$POLL_INTERVAL"
        read -r state gen < <(poll_state "$addr")
        case "$state" in
            failed)
                log "[$name] activation FAILED (push-activate.service failed):"
                ssh -o BatchMode=yes -o ConnectTimeout=10 "$addr" \
                    'journalctl -u push-activate.service -n 15 --no-pager 2>/dev/null | tail -15' \
                    2>/dev/null | sed "s/^/[$TAG] [$name]   /" || true
                return 1
                ;;
            activating | sshfail)
                : # still running, or a transient poll hiccup — keep waiting
                ;;
            *)
                # Oneshot done (inactive/dead) — success iff the generation flipped
                # to the target closure. (A no-op re-activation matches immediately.)
                if [ "$gen" = "$toplevel" ]; then
                    log "[$name] activated ($toplevel)"
                    return 0
                fi
                ;;
        esac
    done

    log "[$name] timed out after ~$((POLL_INTERVAL * POLL_MAX))s waiting for activation"
    return 1
}

# Parse HOST_MAP: comma-separated "name:addr"
IFS=',' read -ra ENTRIES <<< "$HOST_MAP"
for entry in "${ENTRIES[@]}"; do
    [ -n "$entry" ] || continue
    push_deploy_host "$entry" || { any_fail=1; true; }
done

exit "$any_fail"
