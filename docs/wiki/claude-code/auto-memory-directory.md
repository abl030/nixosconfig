# autoMemoryDirectory — Shared Memory via Git

**Date researched:** 2026-03-13
**Updated:** 2026-05-29 — implementing code moved from the retired
`homelab.claudeCode` module to the `claudePrivacy` activation in
`modules/home-manager/profiles/base.nix` (native-module migration, issue #261).
The mechanism is unchanged (still a project-level `.claude/settings.local.json`
write); only the file that performs it moved.
**Status:** Working
**Claude Code version:** Latest (March 2026 release)

## What It Does

`autoMemoryDirectory` is a Claude Code setting that redirects where auto-memory files (MEMORY.md + topic files) are stored. Instead of the default `~/.claude/projects/<project>/memory/`, you can point it at a repo-tracked directory.

## How We Use It

Memory lives at `.claude/memory/` in the nixosconfig repo. The
`home.activation.claudePrivacy` block in `modules/home-manager/profiles/base.nix`
writes the setting into the **project-level** `.claude/settings.local.json`
during activation, so:

- Only affects this project (not other repos)
- Each machine gets its own `settings.local.json` (gitignored) but all point to the same repo-relative path
- Memory content in `.claude/memory/` is git-tracked and syncs across machines

### Configuration

There is no longer a dedicated option — the repo path is hardcoded to
`~/nixosconfig/.claude/memory` inside the `claudePrivacy` activation (the same
script that manages the privacy env flags). See
[claude-codex-native-migration.md](claude-codex-native-migration.md) for why we
hand-merge into the mutable settings file rather than letting the native
`programs.claude-code.settings` own it.

### What the activation script does

1. Sets `.autoMemoryDirectory = "<home>/nixosconfig/.claude/memory"` via `jq`
2. Writes it into `<home>/nixosconfig/.claude/settings.local.json` (creates `{}` if missing), only when `<home>/nixosconfig/.claude` exists
3. Idempotent — same key with same value = no change on repeated rebuilds; other local keys (e.g. permission allow-lists) are preserved

## Key Behaviours

- **Scope:** Global or project-level setting. NOT accepted in project settings checked into git (`.claude/settings.json` in repo root) — security restriction prevents repos from redirecting memory writes.
- **Per-project:** We use `.claude/settings.local.json` (project-level, machine-local) to scope it to just this repo.
- **No subdirectories:** When set, it replaces the path entirely. No per-project subdirectories are created. All projects using the same setting share one directory.
- **Structure:** Same as default — `MEMORY.md` index (first 200 lines loaded at session start) + topic files loaded on demand.

## Replaced Approach

Previously planned a symlink hack (`~/.claude/projects/-home-<user>-nixosconfig/memory → <repo>/.claude/memory/`). The official setting is cleaner and doesn't break on Claude Code upgrades that might change internal paths.

See: deleted `docs/todo/claude-memory-symlink.md`

## Files Involved

- `modules/home-manager/profiles/base.nix` — `home.activation.claudePrivacy` performs the settings.local.json write (and the privacy/agentTeams/plugin-cleanup merges)
- `.claude/memory/MEMORY.md` — the shared memory index
- `.claude/settings.local.json` — gitignored, machine-local, written by activation
- `.gitignore` — ignores `.claude/settings.local.json`
