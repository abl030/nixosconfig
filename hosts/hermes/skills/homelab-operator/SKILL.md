---
name: homelab-operator
description: "Full-operator homelab actions: deploy doc2, ship code (sign+push), bump cratedigger, verify. TUI sessions only."
version: 1.0.0
platforms: [linux]
triggers:
  - deploy doc2
  - deploy to doc2
  - ship this change
  - push and deploy
  - bump cratedigger
  - deploy cratedigger
  - update cratedigger on doc2
  - fix the homelab and deploy
  - apply this to the homelab
metadata:
  hermes:
    tags: [devops, homelab, deploy, operator, cratedigger, nixos, git]
    related_skills: [homelab-triage]
---

# Homelab Operator (deploy / ship / verify)

## When this works

These actions need the **operator keys**, which are forwarded into this container
**only** when the session was launched as `hermes-operator` from the doc1 bastion
(a human is present). In a normal Telegram session the keys are absent and every
command below returns `Permission denied` — that is by design. If a deploy/push
fails with `Permission denied`, you are NOT in an operator session: stop and say
so, don't retry.

Git is pre-configured here: commits are **signed as abl030** automatically and
`git push` goes to Forgejo over SSH. You can verify anything read-only with the
**homelab-triage** skill (Loki).

## The exact commands

- **Deploy doc2** (build + switch verified Forgejo master on doc2):
  - preview:  `ssh abl030@192.168.1.35 dry-run`
  - for real: `ssh abl030@192.168.1.35 deploy`
  This is a forced command — it only ever runs `fleet-update` on doc2; you cannot
  pass other commands.
- **Bump cratedigger** (re-pin `cratedigger-src` to its latest upstream commit and
  push the signed lockfile bump to Forgejo master, on doc1):
  `ssh abl030@192.168.1.29 bump-cratedigger`
  (cratedigger code lives at `github:abl030/cratedigger`; this re-pins to whatever
  is latest there. It prints the new rev, or "no change".)
- **Edit nixosconfig** (homelab config itself): clone
  `https://git.ablz.au/abl030/nixosconfig`, edit, then `git commit` (auto-signed)
  and `git push`. Push only succeeds from an operator session.

## Loops

### Change the homelab config (fully autonomous here)
1. `git clone https://git.ablz.au/abl030/nixosconfig /tmp/nixcfg && cd /tmp/nixcfg`
2. Make the edit (a module under `modules/nixos/services/`, a host under `hosts/`).
3. `git commit -am "<scoped message>"`  (signed automatically)
4. `git push`
5. `ssh abl030@192.168.1.35 deploy`
6. **Verify** with homelab-triage: `{host="doc2", ...}` in Loki — confirm the unit
   is healthy and the change took. Quote the evidence.

### Ship a new cratedigger build to doc2
1. (cratedigger code is already pushed to `github:abl030/cratedigger`.)
2. `ssh abl030@192.168.1.29 bump-cratedigger`  → re-pins cratedigger-src on master
3. `ssh abl030@192.168.1.35 deploy`            → doc2 rebuilds with the new code
4. **Verify**: `{host="doc2", unit=~"cratedigger.*"}` in Loki — look for the
   importer/worker starting clean, no errors.

## Guardrails

- **`deploy` is real and lands on master.** Preview risky homelab edits with
  `dry-run` first; always **verify** afterward via Loki — do not assume success.
- You can deploy **doc2 only**, and bump **cratedigger only** — by design. Don't
  try to reach other hosts.
- Never fabricate success. If a deploy or push errors, read the error and the
  doc2 logs, fix, and retry — or report the blocker plainly.
- Commits are signed for you; do not disable signing (`fleet-update` rejects
  unsigned commits and the deploy will fail).
