# Beads Rollout Plan

**Status**: DEPLOYED (WSL)
**Date**: 2026-02-11

## Context

We're implementing a three-layer agentic memory system (procedural, episodic, semantic). Beads was chosen as Phase 1 (procedural layer) because it's the easiest to package for NixOS (single static Go binary) and provides immediate value for task tracking and session handoffs.

See `docs/agentic-memory-landscape.md` and `docs/agentic-memory-options-comparison.md` for full research.

## Decisions Made

- **beads-mcp**: Included now via `uvx` pattern in `.mcp.json`
- **bd init**: Manual per-project (no automatic init)
- **bd compact**: Deferred (no API key needed yet)
- **Packaging**: Pre-built binary via `fetchurl` in overlay (temporary — see Upstream Tracking below)
- **Hooks**: SessionStart (`bd prime`), PreCompact (`bd sync`) — guarded with `.beads` directory check
- **Deployment**: Fleet-wide via `homelab.claudeCode` module

## What Beads Does

Git-native issue tracker as structured memory for AI agents. Issues stored as JSONL in `.beads/` (git-tracked), cached in SQLite (gitignored). Dependency graph, memory decay via LLM summarization, hash-based IDs for conflict-free multi-agent use.

## Implementation Summary

| File | Action | Description |
|------|--------|-------------|
| `nix/overlay.nix` | Modified | Pre-built binary via `fetchurl` + hash |
| `modules/home-manager/services/claude-code.nix` | Modified | Added `pkgs.beads` to packages |
| `modules/home-manager/profiles/base.nix` | Modified | Added hooks to `claudeCode.settings` |
| `.mcp.json` | Modified | Added beads-mcp server entry |

## Upstream Tracking

**Goal**: Replace `fetchurl` overlay with `inputs.beads.packages` (zero-maintenance flake input).

**Blocker**: The upstream beads flake (`github:steveyegge/beads`) does not build — not with our nixpkgs, not with theirs. A Go dependency (`github.com/dolthub/driver`) requires Go >= 1.25.6, but nixpkgs-unstable only has Go 1.25.5 (upstream Go 1.25.7 and 1.26.0 exist but aren't packaged yet).

**When to migrate**:
1. Check periodically: `nix build "github:steveyegge/beads#default" --no-link`
2. When that succeeds, add beads as a flake input and switch overlay to `inputs.beads.packages`
3. Remove `fetchurl` derivation and hash from overlay

**Current workaround**: Pre-built binary from GitHub Releases. Hash must be manually updated on version bumps. The `version` and `hash` fields in `nix/overlay.nix` are the only things to change.

## Verified

- `which bd` → `/etc/profiles/per-user/nixos/bin/bd`
- `bd --version` → `bd version 0.49.6 (c064f2aa)`
- `~/.claude/settings.json` → hooks for SessionStart (`bd prime`) and PreCompact (`bd sync`) present
- `check` passes

## Open Items

- `bd init` on nixosconfig repo (manual, next step)
- Phase 2: Episodic memory layer
- Phase 3: Semantic memory layer
- `bd compact` enablement (requires Anthropic API key)
