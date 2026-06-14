#!/usr/bin/env bash
# hermes-operator — drop into a FULL-OPERATOR Hermes TUI from the doc1 bastion.
#
# Forwards a SCOPED, ephemeral ssh-agent (only the operator keys) into the hermes
# container, so the session can deploy/push/sign/verify AS YOU for its lifetime —
# no standing key on the hermes box, capability gone the moment you exit.
#
# Security model (see docs/wiki/services/hermes-agent.md, capability-tiers):
#   * A fresh ssh-agent is built per launch holding ONLY the operator keys.
#   * The FLEET key is used to *reach* hermes but supplied from file with
#     AddKeysToAgent=no + IdentitiesOnly=yes, so it NEVER enters the forwarded
#     agent (a naive `ssh -A` would leak it to the container — verified).
#   * /etc/hermes/agent-bridge.py proxies the forwarded agent to a uid-10000
#     socket inside /opt/data; removed on exit.
#
# Inside the session:
#   deploy doc2 : ssh abl030@192.168.1.35 deploy   (check: dry-run)
#   push/sign   : git push  (signs as you; pushes via ssh://git@git.ablz.au:2222)
set -euo pipefail

DEPLOY_KEY="${HERMES_DEPLOY_KEY:-/run/secrets/hermes-deploy-key}"     # doc2 fleet-update (forced-command)
FORGEJO_KEY="${HERMES_FORGEJO_KEY:-/run/secrets/hermes-forgejo-key}"  # Forgejo push (ssh://git@git.ablz.au:2222)
SIGN_KEY="${HERMES_SIGN_KEY:-$HOME/.ssh/id_ed25519_git_sign}"         # commit signing (trusted by fleet-update)
FLEET_KEY="${HERMES_FLEET_KEY:-$HOME/.ssh/id_ed25519}"               # reach hermes (NEVER enters the forwarded agent)

for k in "$DEPLOY_KEY" "$FORGEJO_KEY" "$SIGN_KEY" "$FLEET_KEY"; do
  [ -r "$k" ] || { echo "hermes-operator: missing/unreadable: $k" >&2; exit 1; }
done

# 1. Scoped ephemeral agent — ONLY the operator keys, nothing inherited.
unset SSH_AUTH_SOCK SSH_AGENT_PID
eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
ssh-add -q "$DEPLOY_KEY"   # deploy doc2
ssh-add -q "$FORGEJO_KEY"  # push to Forgejo
ssh-add -q "$SIGN_KEY"     # sign commits as you
echo "hermes-operator: forwarding $(ssh-add -l | wc -l) scoped key(s) into hermes; launching TUI…"

# 2. Forward the scoped agent (fleet key from FILE only so it never lands in the
#    agent), bridge it into the container, exec the interactive TUI.
exec ssh -A -t \
  -o AddKeysToAgent=no -o IdentitiesOnly=yes -i "$FLEET_KEY" \
  hermes '
    set -e
    sudo install -d -m 0700 -o 10000 -g 10000 /var/lib/hermes/.ops
    sudo python3 /etc/hermes/agent-bridge.py "$SSH_AUTH_SOCK" /var/lib/hermes/.ops/agent.sock 10000 10000 &
    cleanup() {
      sudo pkill -f /etc/hermes/agent-bridge.py 2>/dev/null || true
      sudo rm -f /var/lib/hermes/.ops/agent.sock
      sudo rmdir /var/lib/hermes/.ops 2>/dev/null || true
    }
    trap cleanup EXIT
    sleep 1
    sudo podman exec -u hermes -e SSH_AUTH_SOCK=/opt/data/.ops/agent.sock -it hermes hermes
  '
