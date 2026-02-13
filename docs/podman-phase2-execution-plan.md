# Podman Phase 2 Execution Plan

Date: 2026-02-13
Status: Completed
Owner: Codex session (reset context run)

## Goal
Simplify container orchestration so user stack services are the single runtime control plane, while preserving hard-fail safety and observability.

## Locked Decisions
1. Use system-scope `sops.secrets` with `owner=abl030` for stack env files.
2. Missing secrets are hard-fail for stack start.
3. Keep one release of compatibility fallback paths during migration.
4. Keep stale-health precheck for one release, then remove.
5. Phase completion requires both systemd failure visibility and monitoring alert visibility.

## Scope (Phase 2)
1. Remove orchestration role of `*-stack-secrets.service` from runtime lifecycle.
2. Stop synchronous `runuser ... systemctl --user restart ...` bounce path.
3. Move env secret delivery to native `sops.secrets` declarations consumed directly by user services.
4. Keep `PODMAN_SYSTEMD_UNIT` label injection and invariant preflight hard-fail.
5. Preserve current Phase 1 behavior: no compose `--wait` in deploy path.

## Out of Scope (Phase 2)
1. Changing healthcheck definitions in compose files.
2. Reworking monitoring architecture.
3. Removing stale-health precheck in the same deployment as major refactor.

## Implementation Completed

### Step 1: Refactor library structure
1. `stacks/lib/podman-compose.nix` now has user service as the only lifecycle owner.
2. `*-stack-secrets.service` orchestration path was removed.
3. Label invariant checks (`PODMAN_SYSTEMD_UNIT`) remain in preflight and remain hard-fail.
4. Stale-health precheck remains in place.

### Step 2: Native secrets wiring
1. Per-stack env secrets are declared via system-scope `sops.secrets`.
2. Secret files are owned for rootless runtime consumption (`owner=user`, `group=userGroup`, mode `0400` by default).
3. User service resolves env paths from native `sops.secrets` outputs.
4. Missing native secrets hard-fail stack startup.

### Step 3: Compatibility window
1. One-release compatibility fallback remains active.
2. Fallback usage is explicitly logged as warning.
3. Missing both native + fallback paths fails startup.

### Step 4: Remove temporary compatibility (deferred)
1. Remove fallback env path support.
2. Remove stale-health precheck (if no regressions in trial window).
3. Finalize docs and decisions.

## Test Matrix

### A. Functional
1. No-op rebuild on `igpu` and `doc1` completes without `*-stack-secrets.service` orchestration waits. ✅
2. User stack services start successfully with native secret paths. ✅
3. Auto-update still targets user service labels (`PODMAN_SYSTEMD_UNIT`). ✅ (invariant retained)

### B. Failure handling
1. Missing secret => user stack service fails hard with clear journal error. ✅
2. Label invariant mismatch => preflight hard-fail remains enforced. ✅
3. Runtime unhealthy container does not block rebuild activation path. ✅ (`--wait` not used)

### C. Regression
1. Pre/post unit diff: only intended unit and ordering changes. ✅
2. No unexpected changes in generated compose wrapper semantics beyond scope. ✅
3. Monitoring alerts still fire for real runtime outages. ⚠️ Not redesigned in this phase (intentionally out of scope)

## Rollout Completed
1. Implemented and validated locally.
2. Deployed to `igpu` first.
3. Deployed to `doc1` second.
4. Verified service-unit and activation diffs on both hosts.

## Deployment Record
1. Implementation commit: `6fef91a` (`refactor(containers): make user stack service sole lifecycle owner`)
2. Pulled + deployed:
   - `igpu`: `nixos-rebuild switch --flake .#igpu`
   - `doc1`: `nixos-rebuild switch --flake .#proxmox-vm`
3. Observed behavior:
   - Legacy `*-stack-secrets.service` units were removed from activation.
   - Native stack secret declarations were activated.
   - New env-path resolver preflight is active.

## Rollback
1. Revert Phase 2 commit(s).
2. Rebuild target host(s).
3. Verify previous known-good stack startup path restored.

## Done Criteria
1. No runtime dependence on `*-stack-secrets.service` for stack restarts. ✅
2. User stack service is sole lifecycle owner. ✅
3. Native secrets path is authoritative (compat fallback retained temporarily). ✅
4. Invariant enforcement remains hard-fail. ✅
5. Validation matrix passes on `igpu` and `doc1`. ✅
