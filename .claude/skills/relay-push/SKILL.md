---
name: relay-push
description: Land a dev box's signed nixosconfig commits through the doc1 Forgejo bastion. Use for epi/framework review-gated relays and for an explicitly unlocked WSL-to-doc1 agent relay, including "pull commits from WSL", "land WSL's commits", "push the dev box commits", or "gated push".
---

# Relay push

Run on doc1 (`hostname` == `proxmox-vm`), locally or over SSH. Dev boxes
hold no Forgejo push token. Rationale and topology:
`docs/wiki/infrastructure/dev-box-gated-push.md`.

The user's in-session request to land the change is authorization. No extra
"go". Unattended relays still require explicit human approval. For WSL, require
the user-unlocked SSH path and successful `ssh -o BatchMode=yes doc1 hostname`
first. That unlock covers the requested work.

## 1. Fetch and review once

Use the known working SSH address; discover alternatives only if it fails.
WSL: `ssh://wsl/home/nixos/nixosconfig`. Other boxes normally:
`ssh://abl030@<host>/home/abl030/nixosconfig`. epimetheus LAN fallback:
`192.168.1.5`. Only committed objects relay; leave dirty source files alone.

On doc1, fetch without changing the working tree. Substitute source and host:

```bash
git fetch origin master
git fetch <source-url> <source-branch>:refs/incoming/<host>
git log --reverse --format=fuller --show-signature -p origin/master..refs/incoming/<host>
git merge-base --is-ancestor origin/master refs/incoming/<host>
```

In that single review, check each diff matches the request/message and every
signature is good and trusted by `hosts.nix`. Consider security implications
of the actual changes (secrets, auth, privileges, exposure, ownership), without
a separate ceremony for every category. Stop on a real concern or bad signature.

Use those per-commit patches, not a tip-to-tip diff that makes stale source
history look like deletions. Batch remote inspection; do not add SSH round
trips for token existence, repeated status banners, or each review category.
Do not repeat a completed review unless its commits change.

## 2. Preserve commits; replay only when needed

If ancestry succeeds, publish `refs/incoming/<host>` directly. No cherry-pick,
re-signing, temporary branch, or source reset.

If master diverged, replay only the source's new commits onto `origin/master`
in an isolated branch/worktree. Preserve unrelated work. Resolve conflicts,
review the result and verify the new doc1 signatures (`%G?` must be `G`).
Never force-push master. If master advances during publication, fetch and
reconcile before retrying, reviewing and validating any changed result.

## 3. Validate the actual change

- Prose-only docs/instructions: whitespace and content review; check changed
  commands and paths. No `nix flake check`, builds, or deployment.
- Executable/configuration changes: relevant CLAUDE.md checks, including
  `nix flake check` for Nix/config changes. A Markdown suffix alone does not
  make executable/generated inputs prose-only.
- Reuse checks already completed for the exact candidate. Repeat only if a
  replay or other change affects their validity.

For the fast-forward candidate:

```bash
git diff --check origin/master refs/incoming/<host>
```

## 4. Publish and confirm

Use the candidate ref above (normally `refs/incoming/<host>`):

```bash
./scripts/forgejo-auth.sh git-push \
  --repo "$PWD" --remote origin \
  --expected-fetch-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --expected-push-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --token-file /run/secrets/forgejo/nixbot-token \
  --refspec <candidate-ref>:master
git ls-remote origin refs/heads/master
git rev-parse <candidate-ref>
```

Confirm remote SHA matches the candidate. The helper validates remotes and
handles the secret header; never print or transfer the token. Report the commit
and relevant validation concisely, without narrating each gate separately.

Fast-forward clean local master checkouts as needed. With preserved commits,
ordinary `git pull --ff-only` suffices on the source. If replay changed its SHA,
check for new commits and uncommitted work before aligning it to the published
commit; never blindly `reset --hard`. Remove temporary refs/worktrees afterward.

For WSL cellar-manager, publish a feature branch and open/merge its PR via the
Forgejo REST API with `Do = "fast-forward-only"` to preserve signatures.
API guidance: `.claude/memory/forgejo-issue-token-doc1.md`.

Deploy separately when the requested change affects running systems, using
`service-deploy` / `fleet-deploy`. Prose-only changes finish at publication.
