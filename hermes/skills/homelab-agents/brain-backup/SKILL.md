---
name: brain-backup
description: Back up your durable brain and encrypted session snapshots to the private abl030/hermes-brain Forgejo repo while excluding credentials and disposable runtime state.
version: 1.0.0
metadata:
  hermes:
    tags: [hermes, backup, git, memory, skills, forgejo, homelab]
---

# Brain backup

Use this skill to preserve your own durable state in git. Run it after you learn
something worth keeping — a new memory, a new or meaningfully patched skill — and
whenever the user asks you to back up, save, or sync your brain.

Before this repo existed, `~/.hermes` had **no backup of any kind**. doc1's backup
units cover `/nvmeprom/containers` and prom's rpool, not `/home/abl030`. The skill
curator archives unused agent-authored skills after 90 days, and hot skills get
self-patched dozens of times a month with no history. Backing up is how that work
survives.

## Do it

```sh
~/nixosconfig/hermes/skills/homelab-agents/brain-backup/scripts/brain-backup.sh
```

That is the whole operation. The script computes what to save, refuses to run if
anything looks like a credential, commits, and pushes to `main`.

Session history is a separate encrypted snapshot because `state.db` is large,
contains sensitive conversation content, and changes constantly:

```sh
~/nixosconfig/hermes/skills/homelab-agents/brain-backup/scripts/brain-snapshot.sh
```

It takes an online SQLite backup, verifies integrity, compresses it with zstd,
encrypts it to the break-glass and doc1 editor Age recipients, proves local
decryption, then force-replaces the one-commit `snapshots` branch. The disposable
upload repository keeps the opaque ~100 MiB blob out of `~/.hermes/.git`.
The live `~/.hermes/scripts/brain-snapshot.sh` is a tracked, fixed-path wrapper
for this reviewed script so Hermes' script-only weekly cron can invoke it without
an LLM while satisfying Hermes' script-directory confinement.

## What gets saved

| Saved | Never saved |
|---|---|
| `memories/MEMORY.md`, `memories/USER.md` | `.env`, `auth.json`, `auth.lock`, `pairing/` |
| `SOUL.md` | Raw or unencrypted `state.db*` |
| Agent-authored skills under `skills/` | The ~78 skills bundled with the package |
| `webhook_subscriptions.json` | `sessions/`, `logs/`, `bin/`, `worktrees/`, caches |
| `cron/jobs.json`, reviewed script wrapper, `hooks/` | `kanban.db`, `verification_evidence.db` |

The canonical `state.db` is saved only as
`snapshots:sessions/state.db.zst.age`, never on `main` and never unencrypted.

"Authored" is computed each run as: has a `SKILL.md`, leaf name absent from
`skills/.bundled_manifest`, and not inside a read-only nix-store collection. New
skills are therefore picked up automatically — you never maintain a list.

## Rules that are not negotiable

- **Never run `git add -A`, `git add .`, or `git commit -a` in `~/.hermes`.**
  That directory holds live credentials. The repo's `.gitignore` denies
  everything by default precisely so an accident cannot commit them.
- **Never invert or "fix" that `.gitignore`.** If it stops denying by default the
  script refuses to run, and it is right to refuse.
- **Never copy this script into `~/.hermes/skills/`.** It lives in nixosconfig on
  purpose: it is your safety rail, and a self-patchable safety rail is not one.
- **Never push the brain repo's credential anywhere else,** and never use the
  nixosconfig push token for it. `~/.config/hermes-brain/token` belongs to the
  restricted `hermes-brain-writer` user, which is a collaborator on
  `hermes-brain` and nothing else. It cannot see `nixosconfig`.
- The brain repo is **not a deploy root**. Nothing is built or deployed from it,
  so no commit there needs signing and none of it reaches the fleet.
- Never add session ciphertext to `main`. Encrypted files do not delta, so the
  snapshot script force-replaces a root commit on the dedicated branch instead
  of making Git retain every historical 100 MiB version.

## If the preflight aborts

The secret scan fails closed: it prints the offending file and commits nothing.
That is a real finding, not an obstacle to route around.

1. Read the flagged file and find the literal.
2. Replace the value with the *path* or the *sops secret name* — the house style
   is `/run/secrets/<service>/<name>`, never the value itself.
3. Re-run the script.

Do **not** delete the scan, lower its threshold, or `git add -f` past it. If a
credential has already been committed, say so immediately: the fix is rotating
that credential, not quietly rewriting history.

## Verify

```sh
cd ~/.hermes
git log --oneline -3
git ls-files | wc -l                       # tracked path count
git ls-files | grep -E 'auth|\.env|state'  # MUST be empty
```

The script asserts that last check itself after pushing, and fails loudly if a
credential ever became tracked.

For sessions, the snapshot script verifies SQLite integrity, local Age
decryption, zstd integrity, and that Forgejo's `snapshots` ref equals the commit
it uploaded. Inspect the remote metadata with:

```sh
git fetch origin snapshots
git show origin/snapshots:sessions/MANIFEST
```

## Restore

See the Restore section of `~/.hermes/README.md`. Credentials are never restored;
re-run the provider login afterwards. Session restore must happen while Hermes is
stopped and must preserve the old DB/WAL/SHM files until the restored DB opens.
