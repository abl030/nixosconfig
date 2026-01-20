# Homelab Module Standardization Plan

**Status**: COMPLETE
**Started**: 2026-01-19
**Completed**: 2026-01-19

## Problem

Some host-specific features are implemented as direct imports (for example under `hosts/framework/`). This requires manual import management and prevents toggling via `homelab.*` options.

## Goal

Convert loose host `.nix` files into proper `modules/nixos` modules that expose `options.homelab.<feature>.enable`, keeping behavior identical and avoiding drift.

## Scope (Initial Pass)

- `hosts/framework/sleep-then-hibernate.nix`
- `hosts/framework/hibernate_fix.nix`
- `hosts/framework/fingerprint-fix.nix` (currently unused)

## Plan

1. Create `modules/nixos/services/framework/` modules with `mkEnableOption`.
2. Replace host imports with `homelab.framework.*.enable` flags in `hosts/framework/configuration.nix`.
3. Preserve kernel param order by importing the framework module in the host import list.
4. Run `check` and `./scripts/hash-compare.sh --summary`; verify **zero drift**.

## Acceptance Criteria

- No loose host files remain for the scoped features.
- `homelab.framework.*` options toggle the features.
- Drift check reports **MATCH** for all configurations.
