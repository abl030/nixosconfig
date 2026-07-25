---
name: hermes-brain-backup
description: Hermes' durable brain (memories, SOUL, authored skills) backs up to the private abl030/hermes-brain repo; ~/.hermes denies git by default.
metadata:
  type: project
---

Hermes runs on doc1 as the `hermes-gateway.service` **systemd user** service out of
`~/.hermes` — *not* the containerised `/opt/data` VM that older parts of
`docs/wiki/services/hermes-agent.md` still describe (`hosts/hermes/` no longer
exists and `hermes` is not in `hosts.nix`).

Its durable brain is backed up to the **private** repo `abl030/hermes-brain`
(created 2026-07-25). The git worktree *is* `~/.hermes`, so Hermes keeps writing
where it always did. Tracked: `memories/MEMORY.md`, `memories/USER.md`, `SOUL.md`,
`webhook_subscriptions.json`, `cron/jobs.json`, and the agent-authored skills
(38 at setup). Excluded: credentials, `state.db` (300 MB+), caches, and the ~78
package-bundled skills.

`~/.hermes/.gitignore` **denies everything by default** (`*`). Never invert it and
never run `git add -A` there — the directory holds `.env` and `auth.json`. The
reviewed procedure lives in nixosconfig at
`hermes/skills/homelab-agents/brain-backup/` (script + skill), deliberately *not*
in `~/.hermes/skills`, so Hermes cannot self-patch its own safety rails. It
force-adds a per-run computed allow-set and fails closed on a secret scan.

Push credential: `~/.config/hermes-brain/token` (0400) = `write:repository` for the
restricted Forgejo user `hermes-brain-writer`, collaborator on `hermes-brain` only
(verified 404 on nixosconfig). The brain repo is **not a deploy root**; its commits
are unsigned and never reach the fleet.

Caveat: backups are **not yet automated** — Hermes runs the skill when asked or when
it judges it should. A timer is still outstanding.

**Why:** `~/.hermes` had no backup at all (doc1's units cover `/nvmeprom/containers`
and prom's rpool, not `/home/abl030`), while the curator archives unused authored
skills at 90d and Hermes self-patches hot skills dozens of times a month in place.

**How to apply:** to back up, run the `brain-backup` skill. See also
[[forgejo-push-from-doc1]] and [[sops-recipient-model]].
