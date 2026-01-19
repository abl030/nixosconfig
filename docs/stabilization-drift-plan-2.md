# Drift Stabilization Plan (Round 2)

**Status**: COMPLETE
**Started**: 2026-01-19
**Completed**: 2026-01-19

## Goal

Further reduce drift noise from refactors so pure moves or module reshuffles yield **MATCH**. This round explicitly stashes the in-flight service refactor, stabilizes the baseline, captures hashes, then restores the refactor to validate drift.

## Scope

- NixOS + Home Manager configurations in this repo.
- Hash-based drift checks (`./scripts/hash-compare.sh`).
- List ordering stabilization for shared list options.

## Out of Scope

- Functional changes to services or host behavior.
- Concluding the hosts/services refactor itself.

## Workflow (Required Order)

1. **Stash refactor changes**
   - Stash current service-module refactor changes so stabilization is isolated.
2. **Stabilize configs**
   - Fix list ordering (use `lib.mkOrder` to avoid import-order drift).
   - Isolate source paths if any remaining `./` sources are present.
3. **Capture new baseline**
   - Run `./scripts/hash-capture.sh` after stabilization.
4. **Restore refactor changes**
   - Re-apply the stash and reconcile any conflicts.
5. **Drift check**
   - Run `./scripts/hash-compare.sh --summary` and investigate any **DRIFT**.
6. **Iterate**
   - If refactor-only drift remains, add another stabilization fix and repeat steps 2–5.

## Stabilization Tasks (Round 2)

### Phase 1: List Ordering Stabilization
- Add `lib.mkOrder` to any `environment.systemPackages` definitions that still rely on import order.
- Use stable order tiers:
  - Base profiles: 1000 (already used in `modules/nixos/profiles/base.nix`).
  - Shared modules (desktop/common): 1500.
  - Mount modules: 1600.
  - Service modules: 2100+ (sunshine 2200, cockpit 2300, pve 2400, podcast 2500).
  - Host-specific additions: 3000.

### Phase 2: Source Path Isolation (Targeted)
- Re-check for `source = ./...` in NixOS/Home Manager.
- Replace with `builtins.path` or `writeTextFile` if any remain.

### Phase 3: Baseline Refresh
- `./scripts/hash-capture.sh`
- `./scripts/hash-compare.sh --summary` (expect **MATCH**)

### Phase 4: Refactor Validation
- Re-apply the service-refactor stash.
- `./scripts/hash-compare.sh --summary` (expect **MATCH** for refactor-only hosts)
- If drift persists, run `./scripts/hash-compare.sh <host>` to inspect.

## Test Plan

- `./scripts/hash-compare.sh --summary`
- `./scripts/hash-capture.sh`
- `./scripts/hash-compare.sh --summary` after stash re-apply

## Acceptance Criteria

- Baseline drift is clean post-stabilization.
- Refactor-only changes do not introduce drift noise for unaffected hosts.
- Any remaining **DRIFT** maps to a real functional change or a newly identified stabilization gap.
