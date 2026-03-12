# autoMemoryDirectory — Shared Memory via Git

**Date researched:** 2026-03-13
**Status:** Working
**Claude Code version:** Latest (March 2026 release)

## What It Does

`autoMemoryDirectory` is a Claude Code setting that redirects where auto-memory files (MEMORY.md + topic files) are stored. Instead of the default `~/.claude/projects/<project>/memory/`, you can point it at a repo-tracked directory.

## How We Use It

Memory lives at `.claude/memory/` in the nixosconfig repo. The HM module (`modules/home-manager/services/claude-code.nix`) writes the setting into the **project-level** `.claude/settings.local.json` during activation, so:

- Only affects this project (not other repos)
- Each machine gets its own `settings.local.json` (gitignored) but all point to the same repo-relative path
- Memory content in `.claude/memory/` is git-tracked and syncs across machines

### Configuration

```nix
# modules/home-manager/profiles/base.nix
homelab.claudeCode = {
  repoMemoryDirectory = ".claude/memory";  # repo-relative path
  # repoPath defaults to ~/nixosconfig
};
```

### What the activation script does

1. Builds `{"autoMemoryDirectory": "/home/<user>/nixosconfig/.claude/memory"}`
2. Deep-merges it into `<repoPath>/.claude/settings.local.json` (creates if missing)
3. Idempotent — same key with same value = no change on repeated rebuilds

## Key Behaviours

- **Scope:** Global or project-level setting. NOT accepted in project settings checked into git (`.claude/settings.json` in repo root) — security restriction prevents repos from redirecting memory writes.
- **Per-project:** We use `.claude/settings.local.json` (project-level, machine-local) to scope it to just this repo.
- **No subdirectories:** When set, it replaces the path entirely. No per-project subdirectories are created. All projects using the same setting share one directory.
- **Structure:** Same as default — `MEMORY.md` index (first 200 lines loaded at session start) + topic files loaded on demand.

## Replaced Approach

Previously planned a symlink hack (`~/.claude/projects/-home-<user>-nixosconfig/memory → <repo>/.claude/memory/`). The official setting is cleaner and doesn't break on Claude Code upgrades that might change internal paths.

See: deleted `docs/todo/claude-memory-symlink.md`

## Files Involved

- `modules/home-manager/services/claude-code.nix` — options and activation logic
- `modules/home-manager/profiles/base.nix` — sets `repoMemoryDirectory`
- `.claude/memory/MEMORY.md` — the shared memory index
- `.claude/settings.local.json` — gitignored, machine-local, written by activation
- `.gitignore` — ignores `.claude/settings.local.json`
