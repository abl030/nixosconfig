---
name: feedback-devbox-forgejo-creds
description: "Historical warning: dev boxes must not hold Forgejo write credentials; relay through doc1"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5c118cb7-6847-4dd0-88e8-5ac2c8d9571b
---

**SUPERSEDED IN DIRECTION (2026-06-21).** This historical note applied to wsl only.
It is not an authorization to install or use a persistent dev-box credential.
Dev boxes now hold NO push token and relay through doc1 (a token on a dev box =
one popped box → signed auto-deployed fleet takeover). See
`docs/wiki/infrastructure/dev-box-gated-push.md` and the relay-push skill.
Endgame: carried FIDO key, touch-per-push. Keep this note only for the wsl
history; do NOT use it to justify a new dev-box token.

The current operator posture is:

- `epimetheus`, `framework`, and `wsl` hold no Forgejo push token.
- doc1 is the sole unattended writer and owns `/run/secrets/forgejo/nixbot-token`.
- Human-gated relays run `scripts/forgejo-auth.sh` on doc1; the helper validates
  the exact Forgejo remote set before reading the token and keeps it out of argv,
  URLs, and trace/debug output.
- Never push unsigned to master; dev boxes sign by default and their keys are in
  `hosts.nix`.
