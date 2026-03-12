# Claude Code Memory Symlink

## Goal

Track Claude Code's auto-memory (MEMORY.md + per-topic memory files) in the repo so all machines share the same memory via git.

## Current State

Claude Code stores per-project memory at:
```
~/.claude/projects/-home-<user>-nixosconfig/memory/
```

This is machine-local, so memories saved on framework aren't available on wsl/epimetheus/etc.

## Plan

1. Move memory files into the repo at `.claude/memory/`
2. Home-manager activation script creates the symlink:
   ```
   ~/.claude/projects/-home-<user>-nixosconfig/memory → <repo>/.claude/memory/
   ```
3. The `<user>` portion must come from `hostConfig.user` in hosts.nix (not hardcoded to `abl030`)
4. The repo path can be derived from `hostConfig.homeDirectory` + `/nixosconfig`
5. The Claude project path encodes the repo path by replacing `/` with `-` and stripping the leading `-`

## Notes

- The project directory path is deterministic: absolute repo path with `/` → `-`
- If repo path differs between machines, each needs its own symlink (currently all use `/home/<user>/nixosconfig`)
- This should live in the `homelab.claudeCode` module alongside the existing activation script
