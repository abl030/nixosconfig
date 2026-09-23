---
name: forgejo-push-from-doc1
description: How to push to Forgejo (git.ablz.au) from doc1 when abl030 has no https credentials
metadata: 
  node_type: memory
  type: project
  originSessionId: 1db6d98d-bee4-4bb8-add1-bf0f900a64ec
---

On doc1, run `forgejo-push [REFSPEC]` (default `HEAD:master`) from inside the
checkout or any worktree of it, then `forgejo-ls-remote` to confirm the remote
SHA. These fixed-argument front ends (`hosts/proxmox-vm/forgejo-push.nix`, #227)
work inside Claude Code's background-job worktree guard, which refuses the raw
form below.

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
