---
name: feedback-devbox-forgejo-creds
description: "Dev boxes (wsl etc.) may hold a persistent Forgejo write credential — don't over-engineer least-privilege for dev-box git creds"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5c118cb7-6847-4dd0-88e8-5ac2c8d9571b
---

**SUPERSEDED IN DIRECTION (2026-06-21).** This applied to wsl only. We did NOT
extend it to epi/framework — the opposite: dev boxes now hold NO push token and
relay through doc1 (a token on a dev box = one popped box → signed auto-deployed
fleet takeover). wsl keeps its token as a grandfathered exception (USB FIDO can't
enter WSL). See `docs/wiki/infrastructure/dev-box-gated-push.md` and the
relay-push skill. Endgame: carried FIDO key, touch-per-push. Keep this note for
the wsl history below; do NOT use it to justify a new dev-box token.

Dev workstations/VMs (wsl, and by extension framework/epimetheus) are allowed to
hold a **persistent plaintext Forgejo write credential** so the human can `git
push` directly. Treat it like "logged into GitHub as abl030" — that is exactly
how the user framed it when I hesitated on security grounds.

**Why:** these are trusted single-user dev boxes. The blast radius of a leaked
repo-write token there is the same as the user being logged into their git host
on that machine — an accepted baseline, NOT a finding. Do not relay pushes
through doc1, mint per-host scoped tokens, or add sops+rebuild machinery for this
unless the user asks.

**How to apply:** to make a dev box push to Forgejo, install a repo-scoped
extraHeader carrying the nixbot token (pass the token over stdin, never argv):
`git -C ~/nixosconfig config "http.https://git.ablz.au/.extraHeader" "Authorization: token <TOK>"`.
Done on wsl 2026-06-19 (origin repointed github→forgejo, master FF'd, dead beads
`.git/hooks/*` bd-shims removed). The doc1 path is different (root-owned secret,
per-push env header) — see [[forgejo-push-from-doc1]]. Still NEVER push unsigned
to master; dev boxes sign by default and their keys are in `hosts.nix`.
