# Memory

## Shell Environment Quirk
- zoxide hook (`__zoxide_z`) causes `cd` commands to fail with exit 127 in Bash tool
- Workaround: use `git -C /path/to/repo` instead of `cd /path && git`

## Critical "Never Do" Rules
- NEVER run `npm install` manually in a Nix-managed Claude Code installation (breaks the store irreparably)
- NEVER flush pfSense firewall states after rule changes — see [feedback_pfsense_no_state_flush.md](feedback_pfsense_no_state_flush.md)
- Source of truth is FORGEJO (`git.ablz.au/abl030/nixosconfig`); push dev commits
  there (origin repointed on doc1). GitHub is a FROZEN ancestor-only fallback —
  NEVER deploy from `github:abl030/nixosconfig` (stale) and never `git push` to it.
  Push from doc1 needs the nixbot token header: [forgejo-push-from-doc1.md](forgejo-push-from-doc1.md).
- File/edit Forgejo ISSUES from doc1 via a scoped nixbot `write:issue` token,
  sops-encrypted doc1-only: [forgejo-issue-token-doc1.md](forgejo-issue-token-doc1.md).
- NEVER push an UNSIGNED commit to master — signed deploys are ENFORCED fleet-wide
  (#235, 2026-06-10). An unsigned/unverifiable commit in a host's deploy range
  loud-fails its nightly `nixos-upgrade`. Commits must be SSH-signed by a key in
  `hosts.nix`; dev machines sign by default. Verified deploy is `ssh <host> "sudo
  fleet-update"`. Full model: `docs/wiki/infrastructure/signed-fleet-deploys.md`.

## Fleet SSH topology (#270, 2026-06-08)
- doc1 is the SSH **bastion** — ONLY host holding the fleet key; all siblings keyless.
- sibling→sibling SSH is DENIED by design; reach siblings via doc1 (stepping-stone).
- Claude runs on doc1 → its deploys to siblings work unchanged. `nix flake check`'s
  `bastionInvariantCheck` enforces exactly one `deployIdentity=true`.
- Full model: `docs/wiki/infrastructure/ssh-bastion-model.md`.

## Secrets model (#234, 2026-06-08)
- Per-host sops scoping + cold break-glass (Bitwarden+paper) + warm doc1 editor key;
  "master" recipient retired (it was the fleet SSH key in age form). Re-key with
  `sops updatekeys` from **inside `secrets/`**. See [sops-recipient-model.md](sops-recipient-model.md).

## Key Decisions
- Hermes agent → **full-operator** build (TUI=full prod creds via ssh-agent fwd, Telegram=read-only by construction). See [hermes-full-operator-posture.md](hermes-full-operator-posture.md).
- Custom Claude Code HM module stays over official `programs.claude-code`
- Episodic-memory plugin disabled (npm-install breaks the Nix store)
- Heavy MCPs (pfsense, unifi, HA) moved to subagent-only in .claude/agents/ to reduce context bloat
- Task tracking lives in GitHub issues (beads removed 2026-04-14 — see `docs/beads-archive.md`)
