# Drift Stabilization Plan

**Status**: IN PROGRESS
**Started**: 2026-01-19

## Goal

Reduce drift noise from refactors by stabilizing source paths, list ordering, and drift checks. The outcome should be that pure refactors yield **MATCH** and only real functional changes show **DRIFT**.

## Scope

- NixOS + Home Manager configurations in this repo.
- Hash-based drift checks (`./scripts/hash-compare.sh`).
- Optional split baseline behavior (NixOS-only vs Home-only drift checks).

## Out of Scope

- Service refactor to modules (paused until stabilization complete).
- Changes to deployment workflows or Proxmox tooling.

## Work Plan

### Phase 1: Source Path Stabilization
- [ ] Identify all flake-root source references used in outputs (configs, assets, scripts).
- [ ] Replace with `builtins.path`, `copyPathToStore`, or `writeTextFile` so unrelated repo edits do not change store paths.
- [ ] Re-run drift checks to confirm reduced churn.

### Phase 2: Deterministic List Ordering
- [ ] Stabilize `environment.systemPackages` (either by explicit `mkOrder` or sorted/unique normalization).
- [ ] Stabilize `systemd.tmpfiles.rules` ordering where it impacts hashes.
- [ ] Document any ordering assumptions that must remain (PATH priority).

### Phase 3: Optional Split Baselines
- [ ] Add flags to drift scripts to check only NixOS or only Home Manager.
- [ ] Ensure summary output is accurate for each mode.
- [ ] Update docs on new flags and usage.

### Phase 4: Validation + Baseline Refresh
- [ ] Run full drift checks and verify **MATCH** for unaffected hosts.
- [ ] Capture new hashes with the stabilized pipeline.
- [ ] Confirm split baseline commands operate as expected.

## Test Plan (Thorough)

### Pre-flight
- [ ] `nix eval .#nixosConfigurations.sandbox.config.system.build.toplevel`
- [ ] `nix eval .#homeConfigurations.sandbox.activationPackage`

### Drift Check Matrix
- [ ] `./scripts/hash-compare.sh --summary`
- [ ] `./scripts/hash-compare.sh nixos-sandbox`
- [ ] `./scripts/hash-compare.sh home-sandbox`
- [ ] `./scripts/hash-compare.sh --nixos-only --summary` (new)
- [ ] `./scripts/hash-compare.sh --home-only --summary` (new)

### Output Stability
- [ ] Confirm no drift on unaffected hosts after refactor-only changes.
- [ ] If drift exists, run `./scripts/hash-compare.sh <host>` for full `nix-diff` and document reason.

### Baseline Capture
- [ ] `./scripts/hash-capture.sh`
- [ ] Re-run `./scripts/hash-compare.sh --summary` to confirm **MATCH**.

### Quality Gate
- [ ] `check`

## Acceptance Criteria

- Pure refactor changes no longer flip hashes for unaffected hosts.
- New flags for split baselines work as documented.
- Full `check` passes with stabilized outputs.

## Rollback Plan

- Revert stabilization changes (single commit) and restore prior hashes.
- Resume refactor work only after stabilization is green again.
