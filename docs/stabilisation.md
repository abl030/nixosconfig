# Stabilisation

**Purpose**: Keep drift checks meaningful by removing refactor noise while preserving real change detection.

## Lessons Learned

- List options are order-sensitive; refactors that change module import order can cause hash drift.
- Referencing the flake source directly (for files, scripts, assets) creates churn when unrelated files change.
- Drift checks only help if the baseline was captured before the refactor being validated.

## Stabilisation Workflow (Refactors)

1. Stash refactor changes (move-only or module reshuffles).
2. Apply stabilisation fixes (ordering, source path isolation).
3. Capture new baselines with `./scripts/hash-capture.sh`.
4. Restore the refactor changes.
5. Run `./scripts/hash-compare.sh --summary` and investigate any **DRIFT**.
6. Repeat until drift is explained or eliminated.

## Stable Ordering Tiers

Use `lib.mkOrder` to avoid import-order drift for list options:

- Base profiles: 1000
- Shared modules (desktop/common): 1500
- Mount modules: 1600
- Service modules: 2100+ (sunshine 2200, cockpit 2300, pve 2400, podcast 2500)
- Host-specific additions: 3000

## Source Path Isolation

When wiring files, scripts, or assets into NixOS/Home Manager:

- Prefer `builtins.path` or `pkgs.writeTextFile` over `./...` in module options.
- Only include the minimal subdirectory or file to avoid flake-source churn.

## Ongoing Maintenance

- New modules that add to list options must use a stable order tier.
- Any drift investigation should record the root cause before updating hashes.
- Update baselines only after validating changes are intentional.
- Keep `docs/hash-verification.md` and this file aligned with new stabilisation practices.
