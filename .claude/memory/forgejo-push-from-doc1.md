---
name: forgejo-push-from-doc1
description: How to pull/push Forgejo (git.ablz.au) repos from doc1 — plain git works; forgejo-push for worktree-guarded jobs
metadata: 
  node_type: memory
  type: project
  originSessionId: 1db6d98d-bee4-4bb8-add1-bf0f900a64ec
---

**Since 2026-10-12, plain git works on doc1.** Use `git pull` / `git push` /
`git clone` against `https://git.ablz.au/...` for every repo nixbot can reach,
private and LFS repos included. A system credential helper in `/etc/gitconfig`
answers from the nixbot token. See `docs/wiki/services/forgejo.md`, "Plain git
from doc1". A new private repo needs nixbot as a collaborator.

The front ends below still work. They are the shape the worktree guard accepts
without a git operand. Use them when plain `git -C /abs/path push` is refused.

On doc1, run `forgejo-push [REFSPEC]` (default `HEAD:master`) from inside the
checkout or any worktree of it, then `forgejo-ls-remote` to confirm the remote
SHA. These fixed-argument front ends (`hosts/proxmox-vm/forgejo-push.nix`, #227)
work inside Claude Code's background-job worktree guard, which refuses the raw
form below. They act on whichever repo `origin` points at, if it is in the
module's `pushModes` (nixosconfig, cullen-carbon, cullen-assistant as of
2026-10-12). A new repo needs both a `pushModes` entry and nixbot added as a
write collaborator.

Both call the checked-in executable boundary. It validates the exact fetch/push
URL sets before reading the 0400 nixbot token and disables tracing in the
short-lived authenticated child. The raw equivalent:

```sh
./scripts/forgejo-auth.sh git-push \
  --repo "$PWD" --remote origin \
  --expected-fetch-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --expected-push-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --token-file /run/secrets/forgejo/nixbot-token \
  --refspec HEAD:master
```

The helper preserves the push exit status. After a successful push, verify the
remote branch SHA before treating the update as durable.
