# Starship Refactor Plan

**Status**: COMPLETE
**Started**: 2026-01-19
**Completed**: 2026-01-19

## Problem

`home/utils/starship.nix` manually generates TOML files and carries a legacy comment about a malformed signature. This bypasses the Home Manager module (`programs.starship.settings`) and introduces extra paths/config churn.

## Goal

Use Home Manager's native `programs.starship.settings` as the single source of truth. Remove manual TOML generation and align shell init to the default `~/.config/starship.toml` produced by HM.

## Plan

1. Rewrite `home/utils/starship.nix` to define `programs.starship` only.
2. Remove per-shell `STARSHIP_CONFIG` overrides and rely on the default config path.
3. Run `check` and `./scripts/hash-compare.sh --summary`; investigate any drift.

## Acceptance Criteria

- Starship settings live only under `programs.starship.settings`.
- No `toml.generate` usage for Starship.
- Drift check shows expected results (document any unexpected changes).
