# Podman Phase 2.5 Implementation Plan

Date: 2026-02-13  
Status: In progress (code implemented; rollout pending)  
Owner: Podman lifecycle track

## Goal

Implement single-owner stack user-unit management via Home Manager while preserving user-scope lifecycle behavior and hard-fail invariants.

## Decision Inputs

1. Ownership decision: `docs/podman/decisions/2026-02-13-home-manager-user-unit-ownership.md`
2. Research basis: `docs/podman/research/home-manager-user-service-migration-research-2026-02.md`
3. Trigger incident: `docs/podman/incidents/2026-02-13-compose-change-propagation-test.md`

## Scope (Phase 2.5)

1. Move stack unit definitions from NixOS `/etc/systemd/user` generation to Home Manager `systemd.user.services`.
2. Keep `${stackName}.service` naming and user-scope lifecycle model.
3. Ensure no dual ownership for the same unit names during and after migration.
4. Add post-switch ownership assertions (`FragmentPath`, `DropInPaths`).
5. Validate user-manager availability behavior as explicit reconciliation gate.

## Out of Scope (Phase 2.5)

1. Re-architecting stack runtime model away from user scope.
2. Redesigning monitoring platform end-to-end.
3. Broad compose healthcheck strategy changes beyond existing safeguards.

## Workstreams

## W1. Ownership Migration

1. Refactor stack unit generation to Home Manager `systemd.user.services`.
2. Remove NixOS `/etc/systemd/user` ownership for migrated stack unit names.
3. Preserve existing runtime behavior:
   - `podman compose up -d --remove-orphans`
   - preflight invariants
   - hard-fail on missing required secrets and label mismatches

## W2. Ownership Invariants

1. Add post-switch checks for each stack unit:
   - `systemctl --user show <unit> -p FragmentPath -p DropInPaths -p UnitFileState`
2. Expected `FragmentPath` for migrated units must resolve under Home Manager user config path.
3. Any mismatch is treated as reconciliation failure.

## W3. Test System and Scenario Harness

Implement and execute the following scenario set in non-prod before prod rollout:

1. S01/S02: unit shadowing and daemon-reload behavior.
2. S03/S04: compose mutation behavior (image/tag and rename).
3. S05/S06: env/secret missing and path drift cases.
4. S07: manual drift and stale symlink/drop-in behavior.
5. S08: auto-update interaction with restart targets.
6. S09: unhealthy/starting container edge cases.
7. S10: no-op rebuild idempotency.
8. S11: user-manager unavailable/degraded states.
9. S12: rollback reconciliation.
10. S13: controlled prod-like auto-update e2e (deterministic image refresh + user-service restart path).

Scenario definitions are taken from:
- `docs/podman/research/home-manager-user-service-migration-research-2026-02.md`

S13 execution design (local/non-prod):
1. Run a local registry container (e.g. `localhost:5000`) and a tiny test stack pinned to `localhost:5000/autoupdate-probe:stable` with `io.containers.autoupdate=registry`.
2. Publish v1 image, start stack, confirm container label `PODMAN_SYSTEMD_UNIT=<stack>.service`.
3. Publish v2 to the same tag (`stable`) without changing compose.
4. Trigger `podman-auto-update.service`.
5. Assert:
   - auto-update service exits successfully,
   - target user stack service is restarted (`systemctl --user show ... ActiveEnterTimestamp` changes),
   - container digest/image id changes to v2,
   - expected runtime marker from v2 is observed in logs.
6. Negative subcases:
   - invalid image in registry causes auto-update service failure,
   - post-update container non-running/rollback path raises failure signal.

## W4. Rollout

1. First host: `igpu` (where the collision was reproduced).
2. Second host: `proxmox-vm` (`doc1`).
3. For each host:
   - run ownership assertions
   - run targeted scenario subset (S01, S02, S03, S05, S08, S11, S12)
   - confirm no dual ownership remains

## Execution Update (2026-02-14)

1. Ownership migration implementation is complete in code:
   - stack services now generated via Home Manager user units
   - ownership assertions run post-`reloadSystemd` in Home Manager activation
2. Local non-prod e2e validation completed on `wsl` with dummy stacks:
   - `restart-probe-stack.service`
   - `restart-probe-b-stack.service`
3. Change-propagation mutation validated (`PROBE_VERSION` update observed at runtime).
4. Remaining work is rollout and scenario execution on `igpu` then `proxmox-vm` (`doc1`).

## Success Criteria

1. Stack unit names have single ownership in user config path.
2. No active stack unit resolves to stale `/etc` definitions after migration.
3. Rebuild-driven changes converge under user scope on both rollout hosts.
4. User-manager unavailable conditions are observable and operationally handled.
5. Auto-update restart targeting remains intact and non-regressing.

## Rollback

1. Revert Phase 2.5 commits.
2. Rebuild target host(s).
3. Re-verify unit source path and stack lifecycle behavior.
