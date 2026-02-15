# Podman Phase 2.6 Reliability Hardening Plan

Date: 2026-02-14  
Status: Closed (implemented locally; update-path decision superseded)  
Owner: Podman lifecycle track

## Goal

Close the remaining reliability gaps after Phase 2.5 by implementing:

1. Verified apply/restart semantics for stack services.
2. Automatic drift healing for Home Manager-owned stack unit artifacts.
3. Deterministic reconciliation and provenance auditing for user units.

## Inputs

1. Phase 2.5 plan: `docs/podman/current/phase2.5-home-manager-migration-plan.md`
2. WSL e2e evidence: `docs/podman/incidents/2026-02-14-wsl-phase2.5-e2e-validation.md`
3. Deep research report: `docs/podman/research/2026-02-14-phase25-risk-solutions-report.md`

## Scope

1. Keep user-scope lifecycle ownership (`${stackName}.service`).
2. Keep hardening in stack library and HM/NixOS module layers.
3. Do not depend on Podman compat-path `podman auto-update` for compose stack updates.
4. Run comprehensive non-prod validation on `wsl` and land via local commit.

## Out of Scope

1. Moving stacks to system-scope services.
2. Replacing compose-based stack model.
3. Broad monitoring platform redesign.

## Workstreams

## W1. Verified Restart Semantics (Item 1)

1. Add bounded post-apply verification to stack services (running + optional healthy checks).
2. Make apply/restart contract fail-closed for automation:
   - `systemctl --user restart <stack>.service` must return non-zero if desired state is not achieved.
3. Keep logs explicit when apply fails but prior containers may still be running.
4. Preserve existing stale-health precheck and label mismatch enforcement.

## W2. Drift Auto-Heal for Owned Unit Artifacts (Item 2)

1. Apply Home Manager overwrite policy for stack-owned unit files/drop-ins (`force = true` on owned artifacts only).
2. Do not broaden overwrite behavior to unrelated Home Manager files.
3. Confirm drifted local unit files are replaced on activation without manual cleanup.
4. Keep ownership assertions (`FragmentPath`, `DropInPaths`) active post-switch.

## W3. Deterministic Reconciliation + Provenance Audit (Item 3)

1. Enable Home Manager user-service reconciliation mode (`systemd.user.startServices = "sd-switch"` for relevant hosts/users).
2. Add user-scope provenance audit service/timer:
   - checks `FragmentPath`, `DropInPaths`, `NeedDaemonReload`, `UnitFileState`.
   - emits explicit failure/alert signal on provenance violations.
   - optionally auto-runs safe `systemctl --user daemon-reload` when `NeedDaemonReload=yes`.
3. Define fail policy:
   - block-and-alert on provenance violations,
   - auto-heal only safe reload operations.

## W4. Comprehensive WSL Validation

Run all scenarios locally on `wsl` with controlled probe stacks before rollout.

### Baseline Preconditions

1. `wsl` has `homelab.containers.enable = true` and dummy stacks enabled.
2. Compose update orchestration wrapper is current.
3. Local registry test harness (`localhost:5000`) is available for deterministic image updates.

### Test Matrix

1. T01: no-op rebuild idempotency (no unintended restarts).
2. T02: verified restart success path.
3. T03: verified restart failure path (forced unhealthy container) returns non-zero.
4. T04: missing env/secret path path returns unambiguous failure semantics.
5. T05: manual drift replacement of managed unit file is auto-healed on activation.
6. T06: stale drop-in detection path via provenance auditor.
7. T07: `NeedDaemonReload` handling path via provenance auditor.
8. T08: user-manager unavailable/degraded behavior remains explicit and recoverable.
9. T09: stale/unhealthy container cleanup remains effective.
10. T10: controlled compose update e2e pass (v1 -> v2 image change, stack update path changed, logs show new marker).
11. T11: controlled compose update negative cases:
    - pull/update command failure surfaces as service failure,
    - per-stack update failure triggers global failure signal.
12. T12: rollback/reconciliation check after induced faults.

### Required Evidence per Test

1. `systemctl --user show <unit> -p FragmentPath -p DropInPaths -p NeedDaemonReload -p ActiveState -p Result`
2. `journalctl --user -u <unit>` tail for behavior evidence.
3. Podman evidence as needed (`podman ps`, `podman inspect`, compose pull/up logs).
4. A single incident record capturing commands, observations, and PASS/FAIL per test.

## W5. Completion and Handoff

1. Implement W1/W2/W3 locally on `wsl`.
2. Execute full W4 matrix on `wsl` with evidence.
3. Commit Phase 2.6 implementation + evidence updates.
4. Mark Phase 2.6 status as complete in docs.
5. Host deployment was completed via the Phase 2.5 track (`igpu`, `doc1`).

## Success Criteria

1. Restart/apply outcomes are automation-safe and unambiguous.
2. Drifted stack unit artifacts self-heal without manual intervention.
3. Provenance violations are detected deterministically and surfaced.
4. WSL comprehensive matrix passes with recorded evidence.
5. Phase 2.6 changes are committed locally and documented as complete.

## Local Outcome (WSL)

1. W1/W2/W3 were implemented locally on `wsl`.
2. W4 matrix was executed with mixed outcomes:
   - PASS: T01, T02, T07, update failure propagation.
   - PARTIAL: T03 (verify failure reproduced, but restart exit-code semantics still non-authoritative for oneshot pattern).
   - FAIL/LIMITED: T05 no-op drift auto-heal (requires HM activation), T06 blocked by WSL `/etc` read-only constraint.
3. Subsequent decision: remove dependence on Podman compat-path auto-update for compose stacks due to `RawImageName` failures; use compose pull/redeploy orchestration instead.
4. Evidence:
   - `docs/podman/incidents/2026-02-14-wsl-phase2.6-validation.md`
   - `docs/podman/research/2026-02-15-podman-autoupdate-compose-raw-image-report.md`

## Residual Risk Acceptance

1. Restart exit-code ambiguity (oneshot) is accepted, with runtime monitoring as the operational safety net.
2. Deploy/apply readiness gating in systemd is intentionally relaxed to avoid `--wait`-style rebuild stalls on large stacks.
3. No-op rebuild drift auto-heal limitation is accepted, given standard rebuild flow includes Home Manager activation.
4. `/etc` drop-in tampering/provenance violation risk is accepted as low-likelihood in current homelab operating assumptions.
5. Compose updates now rely on compose pull/redeploy units, not Podman metadata-dependent auto-update.

## Rollback

1. Revert Phase 2.6 commits.
2. `nixos-rebuild switch` target host.
3. Re-check stack ownership and runtime behavior:
   - `FragmentPath`
   - `DropInPaths`
   - stack restart and compose update path.
