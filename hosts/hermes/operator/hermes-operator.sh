#!/usr/bin/env bash
# hermes-operator — drop into a FULL-OPERATOR Hermes TUI from the doc1 bastion.
#
# Forwards a SCOPED, ephemeral ssh-agent (only the operator keys) into the hermes
# container, so the session can deploy/verify AS YOU for its lifetime — no
# standing key on the hermes box, capability gone the moment you exit.
#
# Security model (see docs/wiki/services/hermes-agent.md, capability-tiers):
#   * A fresh ssh-agent is built per launch holding ONLY the operator keys.
#   * The FLEET key is used to *reach* hermes but supplied from file with
#     AddKeysToAgent=no + IdentitiesOnly=yes, so it NEVER enters the forwarded
#     agent (a naive `ssh -A` would leak it to the container — verified).
#   * agent-bridge.py proxies the forwarded agent to a uid-10000 socket inside
#     /opt/data; removed on exit.
#
# The deploy key is forced-command-locked on doc2 (deploy | dry-run only). To
# deploy from inside the session:  ssh abl030@192.168.1.35 deploy
#                       (check):   ssh abl030@192.168.1.35 dry-run
set -euo pipefail

DEPLOY_KEY="${HERMES_DEPLOY_KEY:-$HOME/.ssh/hermes-deploy}"
FLEET_KEY="${HERMES_FLEET_KEY:-$HOME/.ssh/id_ed25519}"
BRIDGE_SRC="${HERMES_BRIDGE:-$(cd "$(dirname "$0")" && pwd)/agent-bridge.py}"

[ -r "$DEPLOY_KEY" ] || { echo "hermes-operator: missing deploy key: $DEPLOY_KEY" >&2; exit 1; }
[ -r "$FLEET_KEY" ]  || { echo "hermes-operator: missing fleet key: $FLEET_KEY" >&2; exit 1; }
[ -r "$BRIDGE_SRC" ] || { echo "hermes-operator: missing bridge: $BRIDGE_SRC" >&2; exit 1; }

# 1. Scoped ephemeral agent — ONLY the operator keys, nothing inherited.
unset SSH_AUTH_SOCK SSH_AGENT_PID
eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
ssh-add -q "$DEPLOY_KEY"
# Signing / Forgejo-push keys get added here once the push identity is wired:
#   ssh-add -q "$HOME/.ssh/<forgejo-push-key>"
echo "hermes-operator: forwarding $(ssh-add -l | wc -l) scoped key(s) into hermes; launching TUI…"

# 2. Ship the bridge, forward the scoped agent (fleet key from FILE only), bridge
#    it into the container, exec the interactive TUI.
scp -q "$BRIDGE_SRC" hermes:/tmp/agent-bridge.py
exec ssh -A -t \
  -o AddKeysToAgent=no -o IdentitiesOnly=yes -i "$FLEET_KEY" \
  hermes '
    set -e
    sudo install -d -m 0700 -o 10000 -g 10000 /var/lib/hermes/.ops
    sudo python3 /tmp/agent-bridge.py "$SSH_AUTH_SOCK" /var/lib/hermes/.ops/agent.sock 10000 10000 &
    cleanup() {
      sudo pkill -f /tmp/agent-bridge.py 2>/dev/null || true
      sudo rm -f /var/lib/hermes/.ops/agent.sock
      sudo rmdir /var/lib/hermes/.ops 2>/dev/null || true
    }
    trap cleanup EXIT
    sleep 1
    sudo podman exec -u hermes -e SSH_AUTH_SOCK=/opt/data/.ops/agent.sock -it hermes hermes
  '
